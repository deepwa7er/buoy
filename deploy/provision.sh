#!/usr/bin/env bash
#
# Provision buoy-server's infrastructure on the VPS:
#   - the `buoy` service user (least privilege)
#   - the directory layout: /opt/buoy/web (assets), /opt/buoy/models (model),
#     /var/lib/buoy (the SQLite store), /etc/buoy (config)
#   - the config (installed only if absent; binds loopback, fronted by breakwater)
#   - the all-MiniLM-L6-v2 embedding model (downloaded once; enables semantic
#     search — without it the server runs keyword-only)
#   - the systemd unit
#
# Run this for first-time setup and on infra changes. Routine code/asset deploys
# go through tugboat (deploy.toml at the repo root), not this script — so this
# does NOT build, install the binary/web assets, or restart the service.
#
# Host: set BUOY_HOST (defaults to the `deepwa7er` ssh alias).
set -euo pipefail

HOST="${BUOY_HOST:-deepwa7er}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # deploy/
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REMOTE=/opt/buoy/provision

echo ">> Syncing unit/config to $HOST ..."
ssh "$HOST" "mkdir -p '$REMOTE'"
rsync -az "$PROJECT_DIR/crates/server/buoy.toml" "$HOST:$REMOTE/buoy.toml"
rsync -az "$SCRIPT_DIR/buoy.service" "$HOST:$REMOTE/buoy.service"

echo ">> Provisioning on $HOST ..."
ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
P=/opt/buoy/provision

# --- Service user (least privilege) -----------------------------------------
if ! id buoy >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin buoy
fi

# --- Directory layout -------------------------------------------------------
mkdir -p /opt/buoy/web /opt/buoy/models /var/lib/buoy /etc/buoy
[ -f /etc/buoy/config.toml ] || install -m644 "$P/buoy.toml" /etc/buoy/config.toml

# bind is loopback (see config.toml); breakwater is the tailnet front door.
# The store directory must be writable by the service user.
chown -R buoy:buoy /var/lib/buoy /etc/buoy

# --- Embedding model (downloaded once) --------------------------------------
MODEL_DIR=/opt/buoy/models/all-MiniLM-L6-v2
mkdir -p "$MODEL_DIR"
for f in model.safetensors tokenizer.json config.json; do
  if [ ! -f "$MODEL_DIR/$f" ]; then
    echo ">> Fetching model: $f"
    curl -sL -o "$MODEL_DIR/$f" \
      "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/$f"
  fi
done
chown -R buoy:buoy /opt/buoy

# --- systemd unit -----------------------------------------------------------
install -m644 "$P/buoy.service" /etc/systemd/system/buoy.service
systemctl daemon-reload
systemctl enable buoy.service >/dev/null 2>&1 || true
echo ">> Provisioned. Ship code/assets with tugboat (deploy.toml)."
REMOTE

echo ">> Done."
