# Copy to config.sh and adjust as required.
# SSH private key used when inventory identity_file is '-'.
SSH_KEY="$HOME/.ssh/id_ed25519"

# Standard OpenSSH known-hosts file. Populate it after verifying fingerprints.
KNOWN_HOSTS="$HOME/.ssh/known_hosts"

# Parallelism: 10 is a sensible starting point for 10-50 servers.
MAX_PARALLEL=10

CONNECT_TIMEOUT=10
SERVER_ALIVE_INTERVAL=30
SERVER_ALIVE_COUNT_MAX=3

# Never set this to "no" in production.
STRICT_HOST_KEY_CHECKING="yes"

LOG_DIR="$ROOT_DIR/logs"

# Optional extra OpenSSH options, whitespace-separated.
# Example: SSH_EXTRA_OPTS="-o PreferredAuthentications=publickey"
SSH_EXTRA_OPTS=""
