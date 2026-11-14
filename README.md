# Linux Multi-Server Manager

A Bash/OpenSSH utility for managing 10–50 Linux servers concurrently using SSH public-key authentication. It supports inventory listing, connectivity checks, basic health monitoring, remote command execution, and SCP file transfer.

## Requirements

- Linux, macOS, or another Unix-like management host
- Bash 4.3 or newer (uses `wait -n`)
- OpenSSH client (`ssh` and `scp`)
- SSH public-key authentication configured on every target
- Host keys verified and present in the configured `known_hosts` file

## Install

```bash
unzip linux-multi-server-manager.zip
cd linux-multi-server-manager
cp config.example.sh config.sh
cp servers.example.tsv servers.tsv
chmod 700 bin/mssh
chmod 600 config.sh servers.tsv
```

Edit `servers.tsv`. It is tab-separated with exactly four columns:

```text
host    user    port    identity_file
```

Use a literal tab between columns. Set identity_file to `-` to use `SSH_KEY` from `config.sh`. Example:

```text
app01.example.net    deploy    22    -
db01.example.net     ops       2222  /home/admin/.ssh/db_ed25519
```

Edit `config.sh` and set the correct key, known-hosts path, and parallelism. The config file is sourced as Bash, so only use a file you trust.

## Host-key setup (important)

Do not turn off host-key checking. Obtain each server's SSH host-key fingerprint through a trusted channel (console, cloud control plane, or your infrastructure team), verify it, then add the host key to the `known_hosts` file.

`ssh-keyscan` can collect a candidate key, but it does **not** authenticate the server by itself. Verify its fingerprint before trusting/importing it. Example after independent verification:

```bash
ssh-keyscan -p 22 app01.example.net >> ~/.ssh/known_hosts
ssh-keygen -lf ~/.ssh/known_hosts
```

For nonstandard ports, OpenSSH stores known-host entries in `[host]:port` form. `ssh-keyscan -p PORT host` handles that format.

## Commands

```bash
./bin/mssh list
./bin/mssh check
./bin/mssh check --limit 5
./bin/mssh monitor
./bin/mssh exec -- 'hostname; uptime; df -h'
./bin/mssh copy-to ./release.tar.gz /tmp/release.tar.gz
./bin/mssh copy-from /var/log/syslog ./collected
```

`copy-from` stores each host's result under a separate subdirectory to avoid filename collisions:

```text
collected/
  app01.example.net/
  db01.example.net/
```

Logs are written to `logs/` with a unique run identifier. Protect logs because command output may contain sensitive operational information.

## Interactive tmux dashboard

Launch the fleet dashboard from the repository root:

```bash
chmod 700 bin/system_dashboard.sh
./bin/system_dashboard.sh
```

The dashboard reuses `config.sh` and the same four-column `servers.tsv` inventory as `bin/mssh`. It creates a tmux session containing:

- **GLOBAL-HEALTH** — a fleet-wide table showing connection state, CPU estimate, RAM, swap, maximum filesystem utilization, load average, and failed systemd unit count.
- **One window per inventory host** — detail view with hostname, OS, kernel, uptime, load, CPU, memory, filesystems, top CPU processes, failed systemd units, and network interfaces.
- **COLLECTOR** — a background tmux window that gathers data once per host per refresh cycle. It is created detached and normally stays out of the way.

Offline hosts remain in the dashboard and are marked `OFFLINE`; their windows are not removed. Window names are sanitized versions of the inventory host/IP. Data is collected concurrently, with concurrency bounded by `MAX_PARALLEL`. Cache files are stored in `logs/dashboard-cache/` and written atomically so a display does not read a half-written result.

Options:

```bash
./bin/system_dashboard.sh --refresh 10
./bin/system_dashboard.sh --session production-fleet
```

The default refresh interval is 5 seconds. Override it with `DASHBOARD_REFRESH_INTERVAL` or `--refresh`. Override paths using the existing `MSSH_CONFIG` and `MSSH_INVENTORY` environment variables. The dashboard requires tmux, OpenSSH, and the local `timeout` utility. Remote detail sections use common Linux utilities such as `ps`, `df`, `ip`, and `systemctl`; sections may be empty or unavailable on minimal distributions or systems without systemd/iproute2.

Navigation (tmux default prefix is `Ctrl-b`):

- `Ctrl-b 0`: global fleet overview
- `Ctrl-b w`: choose a host window by its hostname/IP
- `Ctrl-b n` / `Ctrl-b p`: next / previous window
- `Ctrl-b d`: detach; the dashboard session and collector continue
- `tmux kill-session -t linux-fleet`: stop the dashboard and its collector (replace the session name if overridden)

**Security and metric notes:** SSH uses key authentication, `BatchMode=yes`, and `StrictHostKeyChecking=yes`; the script refuses to run if strict checking is disabled. Verify server fingerprints out of band and keep `KNOWN_HOSTS` current. CPU busy is a since-boot estimate from `/proc/stat`, not a delta-based per-refresh utilization reading. The dashboard is a read-only observer; it does not restart services or modify remote hosts. Protect the cache and logs because operational details may be sensitive.

## Security notes

- Use a dedicated least-privilege account and grant only the required `sudo` permissions.
- Protect private keys (`chmod 600 ~/.ssh/id_ed25519`) and use a passphrase/agent where practical.
- Do not put passwords, tokens, or secrets in inventory, command-line arguments, or logs.
- Keep `StrictHostKeyChecking=yes`; verify host fingerprints out of band.
- Restrict inbound SSH with firewalls/VPNs and disable password authentication on servers only after confirming key-based access works.
- Remote commands are executed by the target user's login shell. Only run commands you trust.
- SCP paths are interpreted by the remote SCP implementation; use controlled paths.
- `exec` is designed for administrative commands, not arbitrary untrusted input.

## Operational recommendations for 10–50 hosts

- Start with `MAX_PARALLEL=5` or `10`; increase only after checking bastion, network, and target capacity.
- Test first against a staging host and then a small subset of production hosts.
- Use a dedicated inventory per environment and keep it in access-controlled storage.
- Consider Ansible for complex configuration management, idempotent deployments, secret management, and large fleets. This script is intentionally a lightweight SSH orchestration utility.

## Troubleshooting

- `Permission denied (publickey)`: confirm the correct user/key, server-side `authorized_keys`, and key file permissions.
- `Host key verification failed`: verify the host fingerprint and update `known_hosts` safely; do not bypass checking.
- `Connection timed out`: check routing, firewall rules, VPN/bastion access, port, and server status.
- A server marked failed: inspect its matching log file in `logs/`.

## Configuration overrides

Environment variables can override the config and inventory paths:

```bash
MSSH_CONFIG=/secure/path/config.sh MSSH_INVENTORY=/secure/path/servers.tsv ./bin/mssh check
```
