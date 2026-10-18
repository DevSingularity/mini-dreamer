#!/usr/bin/env bash
#
# Dreamer VPS setup — Ubuntu 22.04 / 24.04
#
# Sets up a full deployment of this repo on a fresh(ish) Ubuntu VPS:
#
#   redis            docker compose (container)        host 127.0.0.1:6380, public via nginx stream 6379
#   api-server       pm2, reads apps/api-server/.env   :5000   -> https://api.<DOMAIN>
#   frontend         pm2 (next start)                  :3000   -> https://home.<DOMAIN>
#   reverse-proxy    pm2                               :8000   -> https://proxy.<DOMAIN>
#   nginx            host-installed                    :80/:443, plus TCP passthrough on :6379
#   certbot          Let's Encrypt (only with your permission)
#
# Usage (as your login user, from the repo root on the VPS):
#   ./deploy/setup-vps.sh            # interactive (asks before certbot)
#   DOMAIN=example.com ./deploy/setup-vps.sh
#
# The script is idempotent — safe to re-run after edits.
#
set -euo pipefail

# ---------------------------------------------------------------- configuration
DOMAIN="${DOMAIN:-ccl.singularitydev.xyz}"
CERT_NAME="${CERT_NAME:-$DOMAIN}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

API_HOST="api.${DOMAIN}"
REDIS_HOST="redis.${DOMAIN}"
HOME_HOST="home.${DOMAIN}"
PROXY_HOST="proxy.${DOMAIN}"

API_PORT=5000
SOCKET_PORT=9002        # socket.io server inside api-server (hardcoded in index.js)
FRONTEND_PORT=3000
RP_PORT=8000
REDIS_HOST_PORT=6380    # host port for the Redis container (6379 is nginx's public stream listener)

NGINX_AVAIL=/etc/nginx/sites-available
NGINX_ENAB=/etc/nginx/sites-enabled
STREAM_DIR=/etc/nginx/stream-enabled
CERT_DIR="/etc/letsencrypt/live/${CERT_NAME}"
WEBROOT=/var/www/html

# ---------------------------------------------------------------- helpers
log()  { printf '\033[1;36m[dreamer]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dreamer] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[dreamer] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this script as root (sudo ./deploy/setup-vps.sh)."

if [ -r /etc/os-release ]; then . /etc/os-release; else die "Cannot detect OS."; fi
[ "${ID:-}" = "ubuntu" ] || warn "This script targets Ubuntu; detected '${ID:-unknown}'. Proceeding anyway."

# ---------------------------------------------------------------- 1. system packages
log "Installing system packages (nginx, certbot, gettext, ufw, node 20, pm2)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx libnginx-mod-stream certbot gettext-base ufw ca-certificates curl gnupg

# Node.js 20 via NodeSource (Ubuntu's apt nodejs is too old for Next.js 16)
NODE_MAJOR="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || true)"
if [ -z "${NODE_MAJOR}" ] || [ "${NODE_MAJOR}" -lt 20 ]; then
    log "Installing Node.js 20 (NodeSource)..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
npm install -g pm2

# Docker (skip if already present)
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    log "Installing docker compose plugin..."
    apt-get install -y docker-compose-v2 || apt-get install -y docker-compose-plugin || true
fi
docker compose version >/dev/null 2>&1 && DC="docker compose" || DC="docker-compose"

# ---------------------------------------------------------------- 2. Redis (docker compose)
ROOT_ENV="$REPO_ROOT/.env"
if [ ! -f "$ROOT_ENV" ]; then
    log "Generating $ROOT_ENV with a random REDIS_PASSWORD..."
    REDIS_PASSWORD="$(openssl rand -hex 16)"
    sed -e "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASSWORD}|" \
        -e "s|^REDIS_HOST_PORT=.*|REDIS_HOST_PORT=${REDIS_HOST_PORT}|" \
        "$REPO_ROOT/.env.example" > "$ROOT_ENV"
    chmod 600 "$ROOT_ENV"
else
    log "Found existing $ROOT_ENV — leaving it untouched."
    REDIS_PASSWORD="$(grep -E '^REDIS_PASSWORD=' "$ROOT_ENV" | cut -d= -f2-)"
    [ -n "$REDIS_PASSWORD" ] || die "REDIS_PASSWORD is empty in $ROOT_ENV"
fi

log "Starting Redis..."
( cd "$REPO_ROOT" && $DC up -d redis )
docker exec dreamer-redis redis-cli -a "$REDIS_PASSWORD" ping >/dev/null 2>&1 \
    || die "Redis did not come up healthy."

# ---------------------------------------------------------------- 3. api-server .env
API_ENV="$REPO_ROOT/apps/api-server/.env"
if [ ! -f "$API_ENV" ]; then
    log "Creating apps/api-server/.env from .env.example (fill in AWS creds later!)"
    cp "$REPO_ROOT/apps/api-server/.env.example" "$API_ENV"
fi
# Wire the API to the dockerized Redis, authenticated via URL.
if grep -qE '^REDIS_URL=' "$API_ENV"; then
    sed -i "s|^REDIS_URL=.*|REDIS_URL=redis://:${REDIS_PASSWORD}@127.0.0.1:${REDIS_HOST_PORT}|" "$API_ENV"
else
    echo "REDIS_URL=redis://:${REDIS_PASSWORD}@127.0.0.1:${REDIS_HOST_PORT}" >> "$API_ENV"
fi
chmod 600 "$API_ENV"
grep -qE '^AWS_ACCESS_KEY_ID=.+' "$API_ENV" \
    || warn "apps/api-server/.env has no AWS credentials yet — /project deployments will fail until you add them."

# ---------------------------------------------------------------- 4. app dependencies + build
log "Installing api-server dependencies..."
( cd "$REPO_ROOT/apps/api-server" && npm install --no-audit --no-fund )
log "Installing reverse-proxy dependencies..."
( cd "$REPO_ROOT/apps/reverse-proxy" && npm install --no-audit --no-fund )
log "Installing + building frontend (takes a minute)..."
( cd "$REPO_ROOT/apps/frontend" && npm install --no-audit --no-fund && npm run build )

# ---------------------------------------------------------------- 5. nginx configs
log "Installing nginx configs..."
install -m 644 "$SCRIPT_DIR/nginx/00-maps.conf" /etc/nginx/conf.d/00-maps.conf

# Stream (TCP) include — append to nginx.conf main context if missing
if ! grep -qE '^\s*include\s+/etc/nginx/stream-enabled/\*\.conf;' /etc/nginx/nginx.conf; then
    printf '\n# Added by dreamer setup-vps.sh — Redis TCP passthrough\ninclude /etc/nginx/stream-enabled/*.conf;\n' >> /etc/nginx/nginx.conf
fi
mkdir -p "$STREAM_DIR"

# Bootstrap HTTP-only server blocks so certbot's webroot challenges can pass.
# These are replaced by the full config once a certificate exists.
write_bootstrap_conf() { # $1 = subdomain FQDN, $2 = upstream port (or "text")
    local host="$1" conf
    conf="$NGINX_AVAIL/dreamer-$1-bootstrap.conf"
    cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${host};
    location /.well-known/acme-challenge/ { root ${WEBROOT}; }
    location / { default_type text/plain; return 200 "dreamer bootstrap - TLS not provisioned yet\\n"; }
}
EOF
    ln -sf "$conf" "$NGINX_ENAB/$(basename "$conf")"
}
for host in "$API_HOST" "$REDIS_HOST" "$HOME_HOST" "$PROXY_HOST"; do
    write_bootstrap_conf "$host"
done
rm -f "$NGINX_ENAB/dreamer.conf" "$NGINX_ENAB/default" 2>/dev/null || true

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- 6. certbot (opt-in)
obtained_cert=0
if [ -f "$CERT_DIR/fullchain.pem" ]; then
    log "Certificate for $CERT_NAME already exists — skipping certbot."
    obtained_cert=1
else
    log "No certificate found for:"
    log "  $API_HOST, $REDIS_HOST, $HOME_HOST, $PROXY_HOST"
    read -r -p "Obtain a Let's Encrypt certificate for these domains now? [y/N] " answer
    case "$answer" in
        [Yy]*)
            read -r -p "Let's Encrypt email address (leave blank to skip email): " le_email
            email_args=(--register-unsafely-without-email)
            [ -n "$le_email" ] && email_args=(-m "$le_email" --agree-tos)
            log "Requesting certificate via webroot..."
            certbot certonly --webroot -w "$WEBROOT" \
                --cert-name "$CERT_NAME" \
                -d "$API_HOST" -d "$REDIS_HOST" -d "$HOME_HOST" -d "$PROXY_HOST" \
                "${email_args[@]}" --non-interactive
            obtained_cert=1
            ;;
        *)
            log "Skipping certbot — nginx stays HTTP-only for now."
            log "(Re-run this script later to provision TLS.)"
            ;;
    esac
fi

# ---------------------------------------------------------------- 7. final nginx config
log "Rendering final nginx site configs..."
export DOMAIN API_HOST REDIS_HOST HOME_HOST PROXY_HOST CERT_NAME
export API_UPSTREAM="127.0.0.1:${API_PORT}"
export SOCKET_UPSTREAM="127.0.0.1:${SOCKET_PORT}"
export FRONTEND_UPSTREAM="127.0.0.1:${FRONTEND_PORT}"
export RP_UPSTREAM="127.0.0.1:${RP_PORT}"
export REDIS_UPSTREAM="127.0.0.1:${REDIS_HOST_PORT}"

if [ "$obtained_cert" -eq 1 ]; then
    # Only substitute our ${VARS}; leave nginx runtime vars ($host, $request_uri...) alone.
    envsubst '${API_HOST} ${REDIS_HOST} ${HOME_HOST} ${PROXY_HOST} ${DOMAIN} ${CERT_NAME} ${API_UPSTREAM} ${SOCKET_UPSTREAM} ${FRONTEND_UPSTREAM} ${RP_UPSTREAM} ${REDIS_UPSTREAM}' \
        < "$SCRIPT_DIR/nginx/sites.conf.template" \
        > "$NGINX_AVAIL/dreamer.conf"
    rm -f "$NGINX_ENAB/dreamer-bootstrap.conf"
    for host in "$API_HOST" "$REDIS_HOST" "$HOME_HOST" "$PROXY_HOST"; do
        rm -f "$NGINX_ENAB/dreamer-${host}-bootstrap.conf"
    done
else
    # HTTP-only: keep bootstrap blocks but make them actually proxy.
    cat > "$NGINX_AVAIL/dreamer.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${API_HOST};
    location /socket.io/ { proxy_pass http://127.0.0.1:${SOCKET_PORT}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; proxy_read_timeout 3600s; }
    location / { proxy_pass http://127.0.0.1:${API_PORT}; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_buffering off; proxy_read_timeout 3600s; }
}
server {
    listen 80;
    listen [::]:80;
    server_name ${HOME_HOST};
    location / { proxy_pass http://127.0.0.1:${FRONTEND_PORT}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; }
}
server {
    listen 80;
    listen [::]:80;
    server_name ${PROXY_HOST};
    location / { proxy_pass http://127.0.0.1:${RP_PORT}; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; proxy_read_timeout 3600s; }
}
server {
    listen 80;
    listen [::]:80;
    server_name ${REDIS_HOST};
    location / { default_type text/plain; return 200 "Redis endpoint: redis://${REDIS_HOST}:6379 (plain TCP, AUTH required)\\n"; }
}
EOF
fi

envsubst '${REDIS_UPSTREAM}' \
    < "$SCRIPT_DIR/nginx/stream.conf.template" \
    > "$STREAM_DIR/redis.conf"

chmod 644 "$NGINX_AVAIL/dreamer.conf" "$STREAM_DIR/redis.conf"
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- 8. pm2 (app processes)
log "Starting app processes under pm2..."
pm2 startOrReload "$SCRIPT_DIR/ecosystem.config.js" --update-env
pm2 save
log "Registering pm2 startup hook (systemd)..."
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 9. firewall (best effort)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "UFW is active — allowing 22, 80, 443, 6379..."
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 6379/tcp >/dev/null
fi

# ---------------------------------------------------------------- 10. verification + summary
log "Waiting a few seconds for processes to settle..."
sleep 5

echo
echo "=========================  status  ========================="
pm2 ls || true
echo
docker ps --filter name=dreamer-redis --format 'redis container: {{.Status}}'
echo
ss -ltnp 2>/dev/null | grep -E ":(5000|3000|8000|9002|6379)\s" || true
echo
echo "socket.io probe (direct :9002):"
curl -fsS --max-time 5 "http://127.0.0.1:9002/socket.io/?EIO=4&transport=polling" 2>/dev/null \
    && echo || warn "socket.io on :9002 did not respond — check: pm2 logs api-server"
echo
echo "=========================  endpoints  ========================="
PUBLIC_IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo '<unknown>')"
echo "Server public IP: $PUBLIC_IP"
for host in "$API_HOST" "$HOME_HOST" "$PROXY_HOST" "$REDIS_HOST"; do
    resolved="$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -n1)"
    if [ -z "$resolved" ]; then
        warn "DNS: $host does not resolve — add an A record pointing to $PUBLIC_IP"
    elif [ "$resolved" != "$PUBLIC_IP" ]; then
        warn "DNS: $host resolves to $resolved, not $PUBLIC_IP"
    else
        echo "DNS ok: $host -> $resolved"
    fi
done
echo
echo "api     https://${API_HOST}   (plain HTTP on :${API_PORT})"
echo "socket  https://${API_HOST}/socket.io/  (proxied to socket.io on :${SOCKET_PORT}; connect with io('https://${API_HOST}'))"
echo "frontend https://${HOME_HOST}  (plain HTTP on :${FRONTEND_PORT})"
echo "proxy   https://${PROXY_HOST}  (plain HTTP on :${RP_PORT})"
echo "redis   redis://${REDIS_HOST}:6379  (plain TCP, AUTH with REDIS_PASSWORD from .env)"
echo
echo "Done. Useful commands:"
echo "  pm2 ls / pm2 logs          # app processes"
echo "  cd $REPO_ROOT && docker compose logs -f redis"
echo "  nano $API_ENV               # AWS creds for api-server"
echo "  ./deploy/setup-vps.sh       # re-run any time (idempotent)"
