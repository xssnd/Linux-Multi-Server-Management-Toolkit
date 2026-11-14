#!/usr/bin/env bash
# Interactive tmux dashboard for a fleet of Linux servers.
# Requires Bash 4.3+, OpenSSH, tmux, awk, sed, date, and standard Linux proc tools remotely.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${MSSH_CONFIG:-$ROOT_DIR/config.sh}"
INVENTORY="${MSSH_INVENTORY:-$ROOT_DIR/servers.tsv}"
CACHE_DIR="${DASHBOARD_CACHE_DIR:-$ROOT_DIR/logs/dashboard-cache}"
REFRESH_INTERVAL="${DASHBOARD_REFRESH_INTERVAL:-5}"
SESSION_NAME="${DASHBOARD_SESSION:-linux-fleet}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
SERVER_ALIVE_INTERVAL="${SERVER_ALIVE_INTERVAL:-30}"
SERVER_ALIVE_COUNT_MAX="${SERVER_ALIVE_COUNT_MAX:-3}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-yes}"
SSH_EXTRA_OPTS="${SSH_EXTRA_OPTS:-}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"

usage() {
  cat <<'EOF'
Linux Multi-Server Dashboard

Usage:
  ./bin/system_dashboard.sh [--refresh SECONDS] [--session NAME]
  ./bin/system_dashboard.sh --help

Controls inside tmux:
  Ctrl-b 0       Global fleet overview
  Ctrl-b 1..9    Select server window
  Ctrl-b n/p     Next/previous server
  Ctrl-b w       Window picker
  q              Quit current dashboard view
  Ctrl-b d       Detach (dashboard keeps running)

Windows are named from each inventory hostname/IP. Offline servers remain visible.
Inventory format: host<TAB>user<TAB>port<TAB>identity_file
Use '-' as identity_file to use SSH_KEY from config.sh.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
safe_name() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9_.-]/_/g'; }

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

while (($#)); do
  case "$1" in
    --refresh) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--refresh requires positive seconds"; REFRESH_INTERVAL="$2"; shift 2 ;;
    --session) [[ -n "${2:-}" ]] || die "--session requires a name"; SESSION_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$REFRESH_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "DASHBOARD_REFRESH_INTERVAL must be positive"
[[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]] || die "MAX_PARALLEL must be positive"
[[ "$STRICT_HOST_KEY_CHECKING" == yes ]] || die "StrictHostKeyChecking must remain 'yes'"

need_cmd tmux
need_cmd ssh
need_cmd awk
need_cmd date
need_cmd timeout
[[ -r "$INVENTORY" ]] || die "Cannot read inventory: $INVENTORY"

declare -a HOSTS=() USERS=() PORTS=() KEYS=() LABELS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  IFS=$'\t' read -r host user port key extra <<< "$line"
  [[ -n "${host:-}" && -n "${user:-}" && -n "${port:-}" && -n "${key:-}" && -z "${extra:-}" ]] ||
    die "Invalid inventory row; expected exactly four TSV columns"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port < 65536)) || die "Invalid port for $host"
  [[ "$host" != -* && "$host" != *[[:space:]]* && "$user" != -* && "$user" != *[[:space:]]* ]] ||
    die "Invalid host/user in inventory"
  [[ "$key" == "-" ]] && key="$SSH_KEY"
  HOSTS+=("$host"); USERS+=("$user"); PORTS+=("$port"); KEYS+=("$key")
  LABELS+=("$(safe_name "$host")")
done < "$INVENTORY"
(("${#HOSTS[@]}" > 0)) || die "Inventory is empty"

mkdir -p -- "$CACHE_DIR" "$LOG_DIR"
chmod 700 "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
LOCK_DIR="$CACHE_DIR/collector.lock"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"

ssh_base() {
  local idx="$1"
  SSH_ARGS=(-i "${KEYS[$idx]}" -p "${PORTS[$idx]}"
    -o BatchMode=yes -o IdentitiesOnly=yes
    -o ConnectTimeout="$CONNECT_TIMEOUT"
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
    -o ServerAliveInterval="$SERVER_ALIVE_INTERVAL"
    -o ServerAliveCountMax="$SERVER_ALIVE_COUNT_MAX" -o LogLevel=ERROR)
  if [[ -n "$SSH_EXTRA_OPTS" ]]; then
    local -a extra
    read -r -a extra <<< "$SSH_EXTRA_OPTS"
    SSH_ARGS+=("${extra[@]}")
  fi
}

# One short, bounded remote probe. Output is key=value lines to keep parsing predictable.
REMOTE_PROBE='
set +e
printf "hostname=%s\n" "$(hostname 2>/dev/null)"
printf "os=%s\n" "$( . /etc/os-release 2>/dev/null; printf "%s" "${PRETTY_NAME:-Linux}" )"
printf "uptime=%s\n" "$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
printf "load=%s\n" "$(awk "{print \$1,\$2,\$3}" /proc/loadavg 2>/dev/null)"
printf "cpu_cores=%s\n" "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "?")"
awk "/^cpu / {u=\$2+\$3; t=u+\$4+\$5+\$6+\$7+\$8; if(t>0) printf \"cpu_busy=%.0f\\n\",100*u/t}" /proc/stat 2>/dev/null
awk "/MemTotal:/ {t=\$2} /MemAvailable:/ {a=\$2} END {if(t>0) printf \"ram_used=%.0f\\nram_total_mb=%.0f\\n\",100*(t-a)/t,t/1024}" /proc/meminfo 2>/dev/null
awk "/SwapTotal:/ {t=\$2} /SwapFree:/ {f=\$2} END {if(t>0) printf \"swap_used=%.0f\\n\",100*(t-f)/t; else print \"swap_used=0\"}" /proc/meminfo 2>/dev/null
df -P -x tmpfs -x devtmpfs 2>/dev/null | awk "NR>1 {gsub(/%/, \"\", \$5); if(\$5>m) m=\$5} END {printf \"disk_max=%d\\n\",m}"
printf "failed_units=%s\n" "$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d " ")"
printf "kernel=%s\n" "$(uname -r 2>/dev/null)"
printf "top_cpu=%s\n" "$(ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | head -n 6 | tail -n 5 | tr \"\\n\" \";\")"
printf "network=%s\n" "$(ip -brief address 2>/dev/null | tr \"\\n\" \";\")"
printf "filesystems=%s\n" "$(df -h -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2 | head -n 8 | tr \"\\n\" \";\")"
'

collect_one() {
  local idx="$1" tmp="$CACHE_DIR/${idx}.tmp" out="$CACHE_DIR/${idx}.data"
  local stamp target rc
  stamp="$(date +%s)"
  target="${USERS[$idx]}@${HOSTS[$idx]}"
  ssh_base "$idx"
  if timeout "$((CONNECT_TIMEOUT + 8))" ssh "${SSH_ARGS[@]}" "$target" "$REMOTE_PROBE" >"$tmp" 2>/dev/null; then
    {
      printf 'status=ONLINE\nupdated=%s\n' "$stamp"
      cat "$tmp"
    } >"$out.new"
  else
    printf 'status=OFFLINE\nupdated=%s\nerror=SSH probe failed\n' "$stamp" >"$out.new"
  fi
  mv -f -- "$out.new" "$out"
  rm -f -- "$tmp"
}

collector_loop() {
  local count="${#HOSTS[@]}" i running pid
  trap 'rm -rf -- "$LOCK_DIR"; rm -f -- "$PID_FILE"; exit 0' INT TERM EXIT
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      : > "$LOCK_DIR/owner"
      running=0
      for ((i=0; i<count; i++)); do
        collect_one "$i" &
        ((running+=1))
        if ((running >= MAX_PARALLEL)); then
          wait -n || true
          ((running-=1))
        fi
      done
      while ((running > 0)); do wait -n || true; ((running-=1)); done
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    sleep "$REFRESH_INTERVAL"
  done
}

read_value() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null
}

render_global() {
  local i file status updated age host cpu ram disk load swap failed
  while :; do
    clear
    printf 'LINUX MULTI-SERVER MANAGER  |  GLOBAL HEALTH  |  %s\n' "$(date '+%F %T')"
    printf 'Refresh: %ss | Servers: %s | Select window 1-%s for details\n\n' "$REFRESH_INTERVAL" "${#HOSTS[@]}" "${#HOSTS[@]}"
    printf '%-3s %-25s %-9s %6s %6s %6s %-15s %5s %s\n' '#' SERVER STATUS CPU RAM DISK LOAD SWAP FAILED
    printf '%s\n' '---------------------------------------------------------------------------------------------------------------'
    for ((i=0; i<${#HOSTS[@]}; i++)); do
      file="$CACHE_DIR/$i.data"; host="${HOSTS[$i]}"
      if [[ -r "$file" ]]; then
        status="$(read_value "$file" status)"; updated="$(read_value "$file" updated)"
        age=$(( $(date +%s) - ${updated:-0} ))
        cpu="$(read_value "$file" cpu_busy)"; ram="$(read_value "$file" ram_used)"
        disk="$(read_value "$file" disk_max)"; load="$(read_value "$file" load)"
        swap="$(read_value "$file" swap_used)"; failed="$(read_value "$file" failed_units)"
      else
        status="WAITING"; age="-"; cpu="-"; ram="-"; disk="-"; load="-"; swap="-"; failed="-"
      fi
      printf '%-3d %-25.25s %-9s %5s%% %5s%% %5s%% %-15.15s %4s%% %s' \
        "$((i+1))" "$host" "$status" "${cpu:--}" "${ram:--}" "${disk:--}" "${load:--}" "${swap:--}" "${failed:--}"
      [[ "$age" != "-" ]] && printf '  (%ss old)' "$age"
      printf '\n'
    done
    printf '\nLegend: CPU/RAM/DISK/SWAP are percentages; FAILED is failed systemd unit count.\n'
    printf 'Keys: Ctrl-b w = window list | Ctrl-b n/p = next/previous | Ctrl-b d = detach\n'
    sleep "$REFRESH_INTERVAL"
  done
}

render_server() {
  local idx="$1" file="$CACHE_DIR/$1.data" key value
  while :; do
    clear
    printf 'SERVER DETAIL  |  %s  |  %s\n\n' "${HOSTS[$idx]}" "$(date '+%F %T')"
    if [[ ! -r "$file" ]]; then
      printf 'Waiting for first collection...\n'
    else
      while IFS='=' read -r key value; do
        case "$key" in
          status) printf 'Connection       : %s\n' "$value" ;;
          updated) printf 'Last collected   : %s\n' "$(date -d "@$value" '+%F %T' 2>/dev/null || printf '%s' "$value")" ;;
          hostname) printf 'Hostname         : %s\n' "$value" ;;
          os) printf 'Operating system : %s\n' "$value" ;;
          uptime) printf 'Uptime           : %s\n' "$value" ;;
          load) printf 'Load average     : %s\n' "$value" ;;
          cpu_cores) printf 'CPU cores        : %s\n' "$value" ;;
          cpu_busy) printf 'CPU busy         : %s%%\n' "$value" ;;
          ram_used) printf 'RAM used         : %s%%\n' "$value" ;;
          ram_total_mb) printf 'RAM total        : %s MB\n' "$value" ;;
          swap_used) printf 'Swap used        : %s%%\n' "$value" ;;
          disk_max) printf 'Max filesystem   : %s%%\n' "$value" ;;
          failed_units) printf 'Failed services  : %s\n' "$value" ;;
          kernel) printf 'Kernel           : %s\n' "$value" ;;
          top_cpu) printf 'Top CPU processes: %s\n' "$value" ;;
          network) printf 'Network          : %s\n' "$value" ;;
          filesystems) printf 'Filesystems      : %s\n' "$value" ;;
          error) printf 'Error            : %s\n' "$value" ;;
        esac
      done < "$file"
    fi
    printf '\nPress Ctrl-b w to switch server; Ctrl-b 0 returns to global view.\n'
    sleep "$REFRESH_INTERVAL"
  done
}

if [[ "${1:-}" == "__collector" ]]; then collector_loop; exit 0; fi
if [[ "${1:-}" == "__global" ]]; then render_global; exit 0; fi
if [[ "${1:-}" == "__server" ]]; then render_server "$2"; exit 0; fi

if [[ -n "${TMUX:-}" ]]; then
  printf 'Run this dashboard outside an existing tmux session.\n' >&2
  exit 2
fi

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  # Run the collector in a hidden tmux window so it stops with the session.
  tmux new-session -d -s "$SESSION_NAME" -n GLOBAL-HEALTH \
    "bash $(printf '%q' "$SCRIPT_PATH") __global"
  tmux new-window -d -t "$SESSION_NAME" -n COLLECTOR \
    "bash $(printf '%q' "$SCRIPT_PATH") __collector"
  for ((i=0; i<${#HOSTS[@]}; i++)); do
    tmux new-window -t "$SESSION_NAME" -n "${LABELS[$i]}" \
      "bash $(printf '%q' "$SCRIPT_PATH") __server $i"
  done
  tmux set-option -t "$SESSION_NAME" status on
  tmux set-option -t "$SESSION_NAME" status-interval "$REFRESH_INTERVAL"
  tmux set-option -t "$SESSION_NAME" status-left '[ FLEET ] '
  tmux set-option -t "$SESSION_NAME" status-right ' Ctrl-b w: servers | Ctrl-b d: detach '
  tmux select-window -t "$SESSION_NAME:0"
fi

tmux attach-session -t "$SESSION_NAME"
