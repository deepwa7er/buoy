#!/usr/bin/env bash
#
# Provision lagoon-server's infrastructure on the VPS:
#   - the `lagoon` service user (least privilege)
#   - the directory layout: /opt/lagoon/web (assets), /opt/lagoon/models (model),
#     /var/lib/lagoon (the SQLite store), /etc/lagoon (config)
#   - the config (installed only if absent; binds loopback, fronted by breakwater)
#   - the all-MiniLM-L6-v2 embedding model (downloaded once; enables semantic
#     search — without it the server runs keyword-only)
#   - the systemd unit
#
# Run this for first-time setup and on infra changes. Routine code/asset deploys
# go through tugboat (deploy.toml at the repo root), not this script — so this
# does NOT build, install the binary/web assets, or restart the service.
#
# Host: set LAGOON_HOST (defaults to the `deepwa7er` ssh alias).
set -euo pipefail

HOST="${LAGOON_HOST:-deepwa7er}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # deploy/
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REMOTE=/opt/lagoon/provision

echo ">> Syncing unit/config to $HOST ..."
ssh "$HOST" "mkdir -p '$REMOTE'"
rsync -az "$PROJECT_DIR/crates/server/lagoon.toml" "$HOST:$REMOTE/lagoon.toml"
rsync -az "$SCRIPT_DIR/lagoon.service" "$HOST:$REMOTE/lagoon.service"

echo ">> Provisioning on $HOST ..."
ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
P=/opt/lagoon/provision

# --- Service user (least privilege) -----------------------------------------
if ! id lagoon >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin lagoon
fi

# --- Directory layout -------------------------------------------------------
mkdir -p /opt/lagoon/web /opt/lagoon/models /var/lib/lagoon /etc/lagoon
[ -f /etc/lagoon/config.toml ] || install -m644 "$P/lagoon.toml" /etc/lagoon/config.toml

# bind is loopback (see config.toml); breakwater is the tailnet front door.
# The store directory must be writable by the service user.
chown -R lagoon:lagoon /var/lib/lagoon /etc/lagoon

# --- Embedding model (downloaded once) --------------------------------------
MODEL_DIR=/opt/lagoon/models/all-MiniLM-L6-v2
mkdir -p "$MODEL_DIR"
for f in model.safetensors tokenizer.json config.json; do
  if [ ! -f "$MODEL_DIR/$f" ]; then
    echo ">> Fetching model: $f"
    curl -sL -o "$MODEL_DIR/$f" \
      "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/$f"
  fi
done
chown -R lagoon:lagoon /opt/lagoon

# --- systemd unit -----------------------------------------------------------
install -m644 "$P/lagoon.service" /etc/systemd/system/lagoon.service
systemctl daemon-reload
systemctl enable lagoon.service >/dev/null 2>&1 || true
echo ">> Provisioned. Ship code/assets with tugboat (deploy.toml)."
REMOTE

echo ">> Done."
