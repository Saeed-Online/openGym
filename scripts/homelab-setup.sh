#!/usr/bin/env bash
# One-time setup of openGym on this Docker host. Two modes:
#
#   LAN / WireGuard — reachable at http://<this host's LAN IP>:<port>, from the home network and
#   from every device on the WireGuard VPN. Nothing is exposed to the internet.
#
#     scripts/homelab-setup.sh --lan                    # first free port from 8090 up
#     scripts/homelab-setup.sh --lan 9100               # first free port from 9100 up
#     LAN_IP=10.10.0.5 scripts/homelab-setup.sh --lan   # pin the address instead of detecting it
#
#   Cloudflare tunnel — reachable at https://<hostname> through cloudflared.
#
#     scripts/homelab-setup.sh gym.example.com [start-port]
#
#   Either mode: add --force as the last argument to replace an existing .env (the old one is
#   kept as .env.bak.<time>).
#
# What it does, and nothing else:
#   1. picks a host port that is free right now AND not claimed by any container (running or
#      stopped), so `docker compose up` cannot collide with the rest of the stack later;
#   2. LAN: finds this host's LAN address. Tunnel: finds the cloudflared container and its network;
#   3. writes .env for that mode;
#   4. validates the result with `docker compose config`.
# It starts nothing. Review .env, then run: docker compose up -d
set -euo pipefail

die() { echo "✗ $*" >&2; exit 1; }

FORCE=""
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--force" ]]; then FORCE=1; else ARGS+=("$a"); fi
done
MODE_ARG="${ARGS[0]:-}"
START_PORT="${ARGS[1]:-8090}"

[[ -n "$MODE_ARG" ]] || die "usage: $0 --lan [start-port] [--force]   or   $0 <public-hostname> [start-port] [--force]"
if [[ "$MODE_ARG" == "--lan" ]]; then
  MODE=lan
else
  MODE=tunnel
  HOST="$MODE_ARG"
  [[ "$HOST" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "'$HOST' is not a hostname (no https://, no path)"
fi
[[ "$START_PORT" =~ ^[0-9]+$ ]] && (( START_PORT >= 1024 && START_PORT <= 65000 )) \
  || die "start port must be a number between 1024 and 65000"

cd "$(dirname "$0")/.."
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (are you in the docker group / using sudo?)"
command -v ss >/dev/null || die "ss not found (apt install iproute2)"

if [[ -e .env && -z "$FORCE" ]]; then
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

# ── 2. mode-specific discovery ─────────────────────────────────────────────────────────────────
TUNNEL_NETWORK=""
if [[ "$MODE" == lan ]]; then
  # The address this host uses to reach the internet is its LAN address — the one WireGuard
  # clients on the FRITZ!Box VPN are routed to.
  if [[ -z "${LAN_IP:-}" ]]; then
    command -v ip >/dev/null || die "ip not found (apt install iproute2) — or set LAN_IP=…"
    LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  fi
  [[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "could not find the LAN address — set LAN_IP=… and rerun"
  ip -4 addr show 2>/dev/null | grep -q "inet $LAN_IP/" \
    || die "$LAN_IP is not an address of this machine — check LAN_IP"
  echo "✓ LAN address: $LAN_IP"
else
  CF_CONTAINER="$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /cloudflared/ {print $1; exit}')"
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
fi

# ── 3. .env ────────────────────────────────────────────────────────────────────────────────────
[[ -e .env ]] && cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
{
  echo "# Written by scripts/homelab-setup.sh ($MODE mode) on $(date -Iseconds). Options: see .env.example."
  if [[ "$MODE" == lan ]]; then
    echo "# ORIGIN must be exactly the address you type in the browser."
    echo "RP_ID=$LAN_IP"
    echo "ORIGIN=http://$LAN_IP:$PORT"
    echo "RP_NAME=openGym"
    echo
    echo "# Published on the LAN address only: reachable from the home network and over WireGuard,"
    echo "# not on other interfaces (Docker networks, anything bound to 127.0.0.1)."
    echo "WEB_BIND=$LAN_IP"
    echo "WEB_PORT=$PORT"
    echo
    echo "# Passkeys need HTTPS, so over plain http the way in is a profile name + password."
    echo "PASSWORD_LOGIN=1"
    echo "TRUST_PROXY=1"
    echo "# CF_CONNECTING_IP stays unset: no Cloudflare in front, so that header must not be trusted."
  else
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
  fi
} > .env
chmod 600 .env
echo "✓ wrote .env"

# ── 4. validate ────────────────────────────────────────────────────────────────────────────────
docker compose config -q || die "docker compose rejected the configuration — see the error above"
RENDERED="$(docker compose config)"
if [[ "$MODE" == lan ]]; then
  grep -q "host_ip: $LAN_IP" <<<"$RENDERED" || die "port is not bound to $LAN_IP in the rendered config"
  grep -q "CF_CONNECTING_IP: \"\"\|CF_CONNECTING_IP: ''\|CF_CONNECTING_IP: *$" <<<"$RENDERED" \
    || die "CF_CONNECTING_IP is set — it must stay empty without Cloudflare in front"
else
  grep -q "host_ip: 127.0.0.1" <<<"$RENDERED" || die "port is not bound to 127.0.0.1 in the rendered config"
  grep -q 'CF_CONNECTING_IP: \$\$http_cf_connecting_ip' <<<"$RENDERED" \
    || die "CF_CONNECTING_IP did not survive interpolation"
fi
echo "✓ docker compose config is valid"

if [[ "$MODE" == lan ]]; then
cat <<EOF

Next steps:

1. Build and start:

   docker compose up -d

2. Check from this machine:

   docker compose ps
   curl -fsS http://$LAN_IP:$PORT/api/health

3. Open on the phone (WireGuard on) or any device at home:

   http://$LAN_IP:$PORT

   Create a profile with a password ("Create new profile" → password).

Plain http means: no passkeys, no push notifications, no installable/offline app, and the
password crosses your home Wi-Fi unencrypted (over WireGuard it is encrypted by the tunnel).
For all of that, HTTPS on the LAN address: docs/SELF_HOSTING_HTTPS.md

EOF
else
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
fi
