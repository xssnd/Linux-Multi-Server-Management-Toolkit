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

The dashboard uses the same `config.sh` and four-column `servers.tsv` inventory as `bin/mssh`. It creates a tmux session with a global fleet overview, one detail window per inventory host (named from its hostname/IP), and a hidden collector window. Offline hosts remain listed and are marked `OFFLINE`.

Useful options:

```bash
./bin/system_dashboard.sh --refresh 10
./bin/system_dashboard.sh --session production-fleet
```

Navigation (tmux default prefix is `Ctrl-b`):

- `Ctrl-b 0`: global fleet overview
- `Ctrl-b w`: open the window picker and select a server by its hostname/IP
- `Ctrl-b w`: interactive window picker
- `Ctrl-b n` / `Ctrl-b p`: next / previous window
- `Ctrl-b d`: detach; the dashboard session continues

The collector polls servers concurrently, bounded by `MAX_PARALLEL`, and writes its short-lived cache under `logs/dashboard-cache/`. The refresh interval defaults to 5 seconds and can be overridden with `DASHBOARD_REFRESH_INTERVAL` or `--refresh`. The dashboard requires tmux on the management host, SSH key authentication, and pre-verified host keys in `KNOWN_HOSTS`; it deliberately refuses to disable strict host-key checking. Close the tmux session to stop its collector.

The overview currently reports SSH reachability, CPU busy estimate, RAM, swap, maximum filesystem utilization, load average, and failed systemd unit count. Values depend on tools and permissions available on each target. CPU busy is a since-boot estimate, not a per-refresh utilization delta.

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
