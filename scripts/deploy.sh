#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/chatapp/app"
VENV_DIR="/opt/chatapp/venv"
STAGING_DIR="/home/ubuntu/viikko5-deploy-staging"
SERVICE_NAME="chatapp"

GIT_SHA="${1:?Usage: deploy.sh GIT_SHA}"

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_DIR="/opt/chatapp/app-backup-${STAMP}"
FAILED_DIR="/opt/chatapp/app-failed-${STAMP}"
VENV_BACKUP="/opt/chatapp/venv-backup-${STAMP}"
FAILED_VENV="/opt/chatapp/venv-failed-${STAMP}"

TMP_DIR=""
OLD_MOVED=0
VENV_BACKED_UP=0
ROLLING_BACK=0

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root." >&2
    exit 1
fi

echo "Deploying revision: ${GIT_SHA}"

rollback() {
    local rc=$?
    trap - ERR
    ROLLING_BACK=1

    echo "ERROR: Deployment failed. Rolling back." >&2

    if [[ "$OLD_MOVED" -eq 1 ]]; then
        if [[ -d "$APP_DIR" ]]; then
            mv "$APP_DIR" "$FAILED_DIR" || true
        fi

        if [[ -d "$BACKUP_DIR" ]]; then
            mv "$BACKUP_DIR" "$APP_DIR" || true
        fi
    fi

    if [[ "$VENV_BACKED_UP" -eq 1 ]]; then
        if [[ -d "$VENV_DIR" ]]; then
            mv "$VENV_DIR" "$FAILED_VENV" || true
        fi

        if [[ -d "$VENV_BACKUP" ]]; then
            mv "$VENV_BACKUP" "$VENV_DIR" || true
        fi
    fi

    if [[ "$OLD_MOVED" -eq 1 || "$VENV_BACKED_UP" -eq 1 ]]; then
        systemctl restart "$SERVICE_NAME" || true
    fi

    exit "$rc"
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap rollback ERR
trap cleanup EXIT

[[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ -d "$STAGING_DIR" && ! -L "$STAGING_DIR" ]]
[[ "$(stat -c '%U:%G' "$STAGING_DIR")" == "ubuntu:ubuntu" ]]
[[ -f "$STAGING_DIR/app.py" ]]
[[ -f "$STAGING_DIR/requirements.txt" ]]
[[ -f "$STAGING_DIR/deploy/sql/schema.sql" ]]
[[ -f "$STAGING_DIR/deploy/systemd/chatapp.service" ]]

[[ -d "$APP_DIR" && ! -L "$APP_DIR" ]]
[[ "$(stat -c '%U:%G' "$APP_DIR")" == "root:root" ]]
[[ -f "$APP_DIR/REVISION" ]]

[[ -d "$VENV_DIR" && ! -L "$VENV_DIR" ]]
[[ "$(stat -c '%U:%G' "$VENV_DIR")" == "root:root" ]]
[[ -x "$VENV_DIR/bin/pip" ]]

[[ ! -e "$BACKUP_DIR" ]]
[[ ! -e "$VENV_BACKUP" ]]

if find "$STAGING_DIR" -type l -print -quit | grep -q .; then
    echo "ERROR: Symlinks in staging are not allowed." >&2
    exit 1
fi

echo "Pre-deployment checks passed."

TMP_DIR="$(mktemp -d /opt/chatapp/app-new.XXXXXX)"

rsync -a --delete \
    --exclude='REVISION' \
    --exclude='.git/' \
    --exclude='.github/' \
    --exclude='.venv/' \
    --exclude='__pycache__/' \
    --exclude='.pytest_cache/' \
    --exclude='.ruff_cache/' \
    --exclude='test_app.py' \
    --exclude='requirements-dev.txt' \
    "$STAGING_DIR/" "$TMP_DIR/"

chown -R root:root "$TMP_DIR"
find "$TMP_DIR" -type d -exec chmod 755 {} \;
find "$TMP_DIR" -type f -exec chmod 644 {} \;

printf '%s\n' "$GIT_SHA" > "$TMP_DIR/REVISION"
chmod 644 "$TMP_DIR/REVISION"

echo "Checking database schema."
mysql chatapp < "$TMP_DIR/deploy/sql/schema.sql"
mysql chatapp -e "SHOW TABLES LIKE 'messages';" | grep -qx messages

echo "Checking Nginx configuration."
nginx -t

echo "Backing up Python virtual environment."
cp -a "$VENV_DIR" "$VENV_BACKUP"
VENV_BACKED_UP=1

echo "Installing Python dependencies."
"$VENV_DIR/bin/pip" install -r "$TMP_DIR/requirements.txt"

echo "Saving current application."
mv "$APP_DIR" "$BACKUP_DIR"
OLD_MOVED=1

echo "Activating new application."
mv "$TMP_DIR" "$APP_DIR"
TMP_DIR=""

echo "Restarting only ${SERVICE_NAME}."
systemctl restart "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME"

sleep 2

ACTUAL_SHA="$(
    curl --silent --show-error --fail --max-time 15 \
        --unix-socket /run/chatapp/gunicorn.sock \
        http://localhost/health |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
)"

[[ "$ACTUAL_SHA" == "$GIT_SHA" ]]

echo "Deployment completed: ${GIT_SHA}"
echo "Application backup: ${BACKUP_DIR}"
echo "Python environment backup: ${VENV_BACKUP}"
