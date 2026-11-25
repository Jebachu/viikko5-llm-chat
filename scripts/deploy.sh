#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/chatapp/app"
VENV_DIR="/opt/chatapp/venv"
ENV_FILE="/etc/chatapp/chatapp.env"
STAGING_DIR="/home/ubuntu/viikko5-deploy-staging"
SERVICE_NAME="chatapp"
NGINX_SNIPPET="/etc/nginx/snippets/chatapp.conf"
NGINX_SITE="/etc/nginx/sites-available/default"
SYSTEMD_UNIT="/etc/systemd/system/chatapp.service"

GIT_SHA="${1:?Usage: deploy.sh GIT_SHA}"

echo "Deploying revision: ${GIT_SHA}"

[[ -d "$STAGING_DIR" && ! -L "$STAGING_DIR" ]] || {
    echo "ERROR: Invalid staging directory" >&2
    exit 1
}

[[ -f "$STAGING_DIR/app.py" ]] || {
    echo "ERROR: app.py missing" >&2
    exit 1
}

[[ -f "$STAGING_DIR/requirements.txt" ]] || {
    echo "ERROR: requirements.txt missing" >&2
    exit 1
}

[[ -f "$STAGING_DIR/deploy/sql/schema.sql" ]] || {
    echo "ERROR: Database schema missing" >&2
    exit 1
}

[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || {
    echo "ERROR: Environment file missing or invalid" >&2
    exit 1
}

[[ -f "$NGINX_SITE" ]] || {
    echo "ERROR: Nginx site configuration missing" >&2
    exit 1
}

[[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: Invalid Git SHA" >&2
    exit 1
}

[[ -d "$APP_DIR" && ! -L "$APP_DIR" ]] || {
    echo "ERROR: Invalid production app directory" >&2
    exit 1
}

[[ "$(stat -c '%U:%G' "$APP_DIR")" == "root:root" ]] || {
    echo "ERROR: Production app directory must belong to root:root" >&2
    exit 1
}

COUNT="$(grep -Ec '^[[:space:]]*server_name _;' "$NGINX_SITE" || true)"
[[ "$COUNT" == "1" ]] || {
    echo "ERROR: Expected exactly one server_name _; entry" >&2
    exit 1
}

echo "Pre-deployment checks passed."

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
    "$STAGING_DIR/" "$APP_DIR/"

chown -R root:root "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;

printf '%s\n' "$GIT_SHA" > "$APP_DIR/REVISION"
chmod 644 "$APP_DIR/REVISION"

"$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

mysql chatapp -e "SHOW TABLES LIKE 'messages';" | grep -qx messages || {
    echo "ERROR: messages table is missing" >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
SNIPPET_EXISTED=0

cp -a "$NGINX_SITE" "$TMP_DIR/default"

if [[ -f "$NGINX_SNIPPET" ]]; then
    SNIPPET_EXISTED=1
    cp -a "$NGINX_SNIPPET" "$TMP_DIR/chatapp.conf"
fi

restore_nginx() {
    cp -a "$TMP_DIR/default" "$NGINX_SITE"

    if [[ "$SNIPPET_EXISTED" == "1" ]]; then
        cp -a "$TMP_DIR/chatapp.conf" "$NGINX_SNIPPET"
    else
        rm -f "$NGINX_SNIPPET"
    fi

    nginx -t
}

install -D -o root -g root -m 644 \
    "$APP_DIR/deploy/nginx/chatapp.conf" "$NGINX_SNIPPET"

if ! grep -Fq "include $NGINX_SNIPPET;" "$NGINX_SITE"; then
    sed -i '/^[[:space:]]*server_name _;/a\
\
        include /etc/nginx/snippets/chatapp.conf;' "$NGINX_SITE"
fi

if ! nginx -t; then
    echo "ERROR: Nginx test failed." >&2
    restore_nginx
    rm -rf "$TMP_DIR"
    exit 1
fi

install -o root -g root -m 644 \
    "$APP_DIR/deploy/systemd/chatapp.service" "$SYSTEMD_UNIT"

if ! systemd-analyze verify "$SYSTEMD_UNIT"; then
    restore_nginx
    rm -rf "$TMP_DIR"
    exit 1
fi

systemctl daemon-reload
systemctl reload nginx

if ! systemctl restart "$SERVICE_NAME"; then
    restore_nginx
    systemctl reload nginx
    rm -rf "$TMP_DIR"
    exit 1
fi

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    restore_nginx
    systemctl reload nginx
    rm -rf "$TMP_DIR"
    exit 1
fi

sleep 2

ACTUAL_SHA="$(
    curl --silent --fail \
        --unix-socket /run/chatapp/gunicorn.sock \
        http://localhost/health |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'
)"

if [[ "$ACTUAL_SHA" != "$GIT_SHA" ]]; then
    echo "ERROR: Version verification failed" >&2
    restore_nginx
    systemctl reload nginx
    rm -rf "$TMP_DIR"
    exit 1
fi

systemctl enable "$SERVICE_NAME"

rm -rf "$TMP_DIR"

echo "Deployment completed: ${GIT_SHA}"
