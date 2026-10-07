#!/usr/bin/env bash
# One-time setup of openGym behind a Cloudflare tunnel on this Docker host.
#
#   scripts/homelab-setup.sh gym.example.com            # first free port from 8090 up
#   scripts/homelab-setup.sh gym.example.com 9100       # first free port from 9100 up
#   scripts/homelab-setup.sh gym.example.com 9100 --force   # replace an existing .env (backed up)
#
# What it does, and nothing else:
#   1. picks a host port that is free right now AND not claimed by any container (running or
#      stopped), so `docker compose up` cannot collide with the rest of the stack later;
#   2. finds the cloudflared container (if any) and the Docker network it is on;
#   3. writes .env: public hostname, localhost-only port, Cloudflare client-IP passthrough,
#      and — when cloudflared runs in Docker on a user network — the tunnel network overlay;
#   4. validates the result with `docker compose config`.
# It starts nothing. Review .env, then run: docker compose up -d
set -euo pipefail

HOST="${1:-}"
START_PORT="${2:-8090}"
FORCE="${3:-}"

die() { echo "✗ $*" >&2; exit 1; }

[[ -n "$HOST" ]] || die "usage: $0 <public-hostname> [start-port] [--force]"
[[ "$HOST" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "'$HOST' is not a hostname (no https://, no path)"
[[ "$START_PORT" =~ ^[0-9]+$ ]] && (( START_PORT >= 1024 && START_PORT <= 65000 )) \
  || die "start port must be a number between 1024 and 65000"

cd "$(dirname "$0")/.."
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (are you in the docker group / using sudo?)"
command -v ss >/dev/null || die "ss not found (apt install iproute2)"

if [[ -e .env && "$FORCE" != "--force" ]]; then
  die ".env already exists — rerun with --force to replace it (the old one is kept as .env.bak.<time>)"
fi

# ── 1. a free port ─────────────────────────────────────────────────────────────────────────────
# Every host port any container on this machine has asked for, running or stopped. A stopped
# container does not hold its port, so `ss` alone would call it free — until that container
# restarts and one of the two fails to start.
claimed_ports() {
  docker ps -aq | xargs -r docker inspect \
    -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' \
    | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}
CLAIMED="$(claimed_ports || true)"

port_busy() {
  local p="$1"
  # Anything listening on it, on any address, TCP — IPv4 or IPv6.
  [[ -n "$(ss -H -ltn "sport = :$p" 2>/dev/null)" ]] && return 0
  grep -qx "$p" <<<"$CLAIMED" && return 0
  return 1
}

PORT=""
for (( p = START_PORT; p < START_PORT + 200; p++ )); do
  if ! port_busy "$p"; then PORT="$p"; break; fi
  echo "  port $p is taken — trying the next one"
done
[[ -n "$PORT" ]] || die "no free port in $START_PORT–$((START_PORT + 199))"
echo "✓ port $PORT is free (nothing listening, no container claims it)"

# ── 2. where cloudflared runs ──────────────────────────────────────────────────────────────────
CF_CONTAINER="$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /cloudflared/ {print $1; exit}')"
TUNNEL_NETWORK=""
TUNNEL_URL="http://localhost:$PORT"
if [[ -n "$CF_CONTAINER" ]]; then
  NETS="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CF_CONTAINER")"
  NET="$(awk '{print $1}' <<<"$NETS")"
  echo "✓ cloudflared container: $CF_CONTAINER (network: ${NETS% })"
  case "$NET" in
    host)   echo "  it uses the host network, so it reaches 127.0.0.1:$PORT directly" ;;
    bridge) echo "  ! it is on Docker's default 'bridge' network, which has no name resolution."
            echo "    Put cloudflared on a user-defined network (any compose file does that) and rerun."
            die "cannot wire the tunnel to openGym from the default bridge network" ;;
    *)      TUNNEL_NETWORK="$NET"; TUNNEL_URL="http://opengym-web:80"
            echo "  openGym's web container will join '$NET' as 'opengym-web'" ;;
  esac
else
  echo "• no cloudflared container running — assuming cloudflared runs on the host (systemd)"
fi

# ── 3. .env ────────────────────────────────────────────────────────────────────────────────────
[[ -e .env ]] && cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
{
  echo "# Written by scripts/homelab-setup.sh on $(date -Iseconds). Options: see .env.example."
  echo "RP_ID=$HOST"
  echo "ORIGIN=https://$HOST"
  echo "RP_NAME=openGym"
  echo
  echo "# Published on localhost only; the Cloudflare tunnel is the way in."
  echo "WEB_BIND=127.0.0.1"
  echo "WEB_PORT=$PORT"
  echo
  echo "# Cloudflare sets this header itself, so it is the real visitor address. Single quotes:"
  echo "# compose must pass the nginx variable through literally, not expand it."
  echo "CF_CONNECTING_IP='\$http_cf_connecting_ip'"
  echo "TRUST_PROXY=1"
  if [[ -n "$TUNNEL_NETWORK" ]]; then
    echo
    echo "# cloudflared runs in Docker: join its network (docker-compose.tunnel.yml)."
    echo "COMPOSE_FILE=docker-compose.yml:docker-compose.tunnel.yml"
    echo "TUNNEL_NETWORK=$TUNNEL_NETWORK"
  fi
} > .env
chmod 600 .env
echo "✓ wrote .env"

# ── 4. validate ────────────────────────────────────────────────────────────────────────────────
docker compose config -q || die "docker compose rejected the configuration — see the error above"
RENDERED="$(docker compose config)"
grep -q "host_ip: 127.0.0.1" <<<"$RENDERED" || die "port is not bound to 127.0.0.1 in the rendered config"
grep -q 'CF_CONNECTING_IP: \$\$http_cf_connecting_ip\|CF_CONNECTING_IP: \$http_cf_connecting_ip' <<<"$RENDERED" \
  || die "CF_CONNECTING_IP did not survive interpolation"
echo "✓ docker compose config is valid"

cat <<EOF

Next steps:

1. In Cloudflare Zero Trust → Networks → Tunnels → your tunnel → Public Hostname, add:

   $HOST  →  $TUNNEL_URL

2. If Cloudflare Access protects $HOST, add a Bypass policy for these paths
   (home-screen icons must load without a login):

   /icon-180.png  /icon-512.png  /manifest.json

3. Build and start:

   docker compose up -d

4. Check:

   docker compose ps
   curl -fsS http://127.0.0.1:$PORT/api/health

EOF
