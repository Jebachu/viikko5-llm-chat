#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/chatapp/app"
VENV_DIR="/opt/chatapp/venv"
ENV_FILE="/etc/chatapp/chatapp.env"
SERVICE_NAME="chatapp"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GIT_SHA="${1:?Usage: deploy.sh GIT_SHA}"

echo "Deploying revision: ${GIT_SHA}"

if [[ ! -d "$APP_DIR" ]]; then
    echo "ERROR: Application directory does not exist: $APP_DIR" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Environment file does not exist: $ENV_FILE" >&2
    exit 1
fi

"$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

printf '%s\n' "$GIT_SHA" > "$APP_DIR/REVISION"

mysql chatapp < "$APP_DIR/deploy/sql/schema.sql"

nginx -t

systemctl restart "$SERVICE_NAME"

systemctl is-active --quiet "$SERVICE_NAME"

echo "Deployment completed: ${GIT_SHA}"
