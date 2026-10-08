#!/usr/bin/env bash
# One-time setup of openGym on this Docker host. Three modes:
#
#   HTTPS on the LAN (recommended) — https://<hostname>, a real Let's Encrypt certificate through a
#   Cloudflare DNS-01 challenge, reachable from the home network and over WireGuard only. Passkeys,
#   notifications, the installable web app and the Android app all work.
#
#     scripts/homelab-setup.sh --https gym.example.com
#     CF_API_TOKEN=… scripts/homelab-setup.sh --https gym.example.com    # token without a prompt
#
#   Plain-http LAN / WireGuard — http://<LAN IP>:<port>, password sign-in only.
#
#     scripts/homelab-setup.sh --lan [start-port]
#
#   Cloudflare tunnel — https://<hostname> through cloudflared.
#
#     scripts/homelab-setup.sh gym.example.com [start-port]
#
#   Every mode: LAN_IP=… pins the LAN address instead of detecting it; --force as the last argument
#   replaces an existing .env (the old one is kept as .env.bak.<time>). Data in ./data is untouched.
#
# What it does, and nothing else: picks ports that are free now AND not claimed by any container
# (running or stopped), finds the LAN address / cloudflared, for --https creates or checks the
# DNS record in Cloudflare, writes .env, and validates it with `docker compose config`.
# It starts nothing. Review .env, then run: docker compose up -d
set -euo pipefail

die() { echo "✗ $*" >&2; exit 1; }

FORCE=""
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--force" ]]; then FORCE=1; else ARGS+=("$a"); fi
done
USAGE="usage: $0 --https <hostname> | --lan [start-port] | <tunnel-hostname> [start-port]   (+ --force)"
MODE_ARG="${ARGS[0]:-}"
[[ -n "$MODE_ARG" ]] || die "$USAGE"
START_PORT=8090
case "$MODE_ARG" in
  --lan)   MODE=lan;    START_PORT="${ARGS[1]:-8090}" ;;
  --https) MODE=https;  HOST="${ARGS[1]:-}"; [[ -n "$HOST" ]] || die "$USAGE" ;;
  -*)      die "$USAGE" ;;
  *)       MODE=tunnel; HOST="$MODE_ARG"; START_PORT="${ARGS[1]:-8090}" ;;
esac
if [[ "$MODE" != lan ]]; then
  [[ "$HOST" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && "$HOST" =~ \.[A-Za-z]{2,}$ ]] \
    || die "'$HOST' is not a hostname (no https://, no path)"
  HOST="${HOST,,}"
fi
[[ "$START_PORT" =~ ^[0-9]+$ ]] && (( START_PORT >= 1024 && START_PORT <= 65000 )) \
  || die "start port must be a number between 1024 and 65000"

cd "$(dirname "$0")/.."
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (are you in the docker group / using sudo?)"
command -v ss >/dev/null || die "ss not found (apt install iproute2)"
if [[ "$MODE" == https ]]; then
  command -v curl >/dev/null || die "curl not found (apt install curl)"
  command -v python3 >/dev/null || die "python3 not found (apt install python3)"
fi

if [[ -e .env && -z "$FORCE" ]]; then
  die ".env already exists — rerun with --force to replace it (the old one is kept as .env.bak.<time>)"
fi

# ── ports ──────────────────────────────────────────────────────────────────────────────────────
# Every host port any container on this machine has asked for, running or stopped. A stopped
# container does not hold its port, so `ss` alone would call it free — until that container
# restarts and one of the two fails to start. openGym's own containers are left out, so a rerun
# with --force can keep the ports it already has.
claimed_ports() {
  local own
  own="$(docker ps -aq --filter "label=com.docker.compose.project=opengym")"
  docker ps -aq | grep -vxF -e "${own:-^$}" | xargs -r docker inspect \
    -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' \
    | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}
CLAIMED="$(claimed_ports || true)"
OWN_PORTS="$(docker ps -q --filter "label=com.docker.compose.project=opengym" | xargs -r docker inspect \
  -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' 2>/dev/null \
  | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"

port_busy() {
  local p="$1"
  grep -qx "$p" <<<"$CLAIMED" && return 0
  # Listening on it, on any address, TCP — IPv4 or IPv6. openGym's own running containers hold
  # their ports too; those count as free for a rerun.
  if [[ -n "$(ss -H -ltn "sport = :$p" 2>/dev/null)" ]]; then
    grep -qx "$p" <<<"$OWN_PORTS" && return 1
    return 0
  fi
  return 1
}
first_free() {  # first_free <start> <count>
  local p
  for (( p = $1; p < $1 + $2; p++ )); do
    if ! port_busy "$p"; then echo "$p"; return 0; fi
    echo "  port $p is taken — trying the next one" >&2
  done
  return 1
}

PORT="$(first_free "$START_PORT" 200)" || die "no free port in $START_PORT–$((START_PORT + 199))"
echo "✓ port $PORT is free for the web container (nothing listening, no other container claims it)"

# ── LAN address (lan, https) ───────────────────────────────────────────────────────────────────
find_lan_ip() {
  # The address this host uses to reach the internet is its LAN address — the one WireGuard
  # clients on the router's VPN are routed to.
  if [[ -z "${LAN_IP:-}" ]]; then
    command -v ip >/dev/null || die "ip not found (apt install iproute2) — or set LAN_IP=…"
    LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  fi
  [[ "$LAN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "could not find the LAN address — set LAN_IP=… and rerun"
  ip -4 addr show 2>/dev/null | grep -q "inet $LAN_IP/" \
    || die "$LAN_IP is not an address of this machine — check LAN_IP"
  echo "✓ LAN address: $LAN_IP"
}

# ── Cloudflare (https) ─────────────────────────────────────────────────────────────────────────
CF_API="https://api.cloudflare.com/client/v4"
cf() {  # cf <method> <path> [json-body]  → prints the response body, dies on an API error
  local out args=(-sS -X "$1" "$CF_API$2" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [[ -n "${3:-}" ]] && args+=(--data "$3")
  out="$(curl "${args[@]}")" || die "cannot reach the Cloudflare API"
  python3 -c 'import json,sys
r = json.loads(sys.argv[1])
if not r.get("success"):
    sys.exit("Cloudflare API: " + "; ".join(e.get("message", "?") for e in r.get("errors", [])))' "$out" \
    || die "Cloudflare refused $1 $2 — check the token's permissions (Zone.Zone:Read + Zone.DNS:Edit)"
  printf '%s' "$out"
}
jget() { python3 -c "import json,sys; r=json.loads(sys.argv[1]); print($2)" "$1"; }

setup_cloudflare() {
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    echo
    echo "A Cloudflare API token is needed (dash.cloudflare.com → My Profile → API Tokens →"
    echo "Create Token → 'Edit zone DNS' template, plus Zone · Zone · Read, limited to your zone)."
    read -rsp "Cloudflare API token: " CF_API_TOKEN; echo
  fi
  [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,}$ ]] || die "that does not look like a Cloudflare API token"
  cf GET /user/tokens/verify >/dev/null
  echo "✓ Cloudflare token is valid"

  # The zone is the longest suffix of the hostname Cloudflare knows (gym.example.co.uk → example.co.uk).
  # The hostname itself must be a subdomain, so the search starts at its parent.
  local name="$HOST" res
  ZONE_ID=""
  while [[ "$name" == *.*.* ]]; do
    name="${name#*.}"
    res="$(cf GET "/zones?name=$name")"
    ZONE_ID="$(jget "$res" 'r["result"][0]["id"] if r["result"] else ""')"
    [[ -n "$ZONE_ID" ]] && { ZONE="$name"; break; }
  done
  [[ -n "$ZONE_ID" ]] || die "no Cloudflare zone for $HOST is visible to this token (use a subdomain, e.g. gym.example.com)"
  echo "✓ zone: $ZONE"

  # Never touch a name already in use for something else — a tunnel hostname is a CNAME, and a
  # proxied A record is serving the internet.
  res="$(cf GET "/zones/$ZONE_ID/dns_records?name=$HOST")"
  local summary
  summary="$(jget "$res" '"|".join(",".join(str(x.get(k)) for k in ("type", "content", "proxied", "id")) for x in r["result"])')"
  if [[ -z "$summary" ]]; then
    cf POST "/zones/$ZONE_ID/dns_records" \
      "{\"type\":\"A\",\"name\":\"$HOST\",\"content\":\"$LAN_IP\",\"ttl\":1,\"proxied\":false,\"comment\":\"openGym, LAN only\"}" >/dev/null
    echo "✓ created DNS record: $HOST → $LAN_IP (DNS only, not proxied)"
  elif [[ "$summary" == "A,$LAN_IP,False,"* && "$summary" != *"|"* ]]; then
    echo "✓ DNS record already in place: $HOST → $LAN_IP (DNS only)"
  else
    echo "  existing records for $HOST: ${summary//|/  }" >&2
    die "$HOST is already used for something else in Cloudflare — pick another name (e.g. gym2.$ZONE)"
  fi
}

# ── mode-specific discovery ────────────────────────────────────────────────────────────────────
TUNNEL_NETWORK=""
case "$MODE" in
  lan)
    find_lan_ip ;;
  https)
    find_lan_ip
    HTTPS_PORT="$(first_free 443 1 2>/dev/null || first_free 8443 20)" || die "neither 443 nor 8443–8462 is free"
    [[ "$HTTPS_PORT" == 443 ]] && echo "✓ port 443 is free for HTTPS" \
      || echo "• port 443 is taken — HTTPS goes on $HTTPS_PORT (the address will carry :$HTTPS_PORT)"
    setup_cloudflare ;;
  tunnel)
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
    fi ;;
esac

# ── .env ───────────────────────────────────────────────────────────────────────────────────────
[[ -e .env ]] && cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
{
  echo "# Written by scripts/homelab-setup.sh ($MODE mode) on $(date -Iseconds). Options: see .env.example."
  case "$MODE" in
  lan)
    echo "# ORIGIN must be exactly the address you type in the browser."
    echo "RP_ID=$LAN_IP"
    echo "ORIGIN=http://$LAN_IP:$PORT"
    echo "RP_NAME=openGym"
    echo
    echo "# Published on the LAN address only: reachable from the home network and over WireGuard."
    echo "WEB_BIND=$LAN_IP"
    echo "WEB_PORT=$PORT"
    echo
    echo "# Passkeys need HTTPS, so over plain http the way in is a profile name + password."
    echo "PASSWORD_LOGIN=1"
    echo "TRUST_PROXY=1"
    echo "# CF_CONNECTING_IP stays unset: no Cloudflare in front, so that header must not be trusted." ;;
  https)
    SUFFIX=""; [[ "$HTTPS_PORT" != 443 ]] && SUFFIX=":$HTTPS_PORT"
    echo "RP_ID=$HOST"
    echo "ORIGIN=https://$HOST$SUFFIX"
    echo "RP_NAME=openGym"
    echo
    echo "# Caddy (docker-compose.https.yml) serves HTTPS on the LAN address only."
    echo "COMPOSE_FILE=docker-compose.yml:docker-compose.https.yml"
    echo "ACME_HOST=$HOST"
    echo "HTTPS_BIND=$LAN_IP"
    echo "HTTPS_PORT=$HTTPS_PORT"
    echo
    echo "# The web container itself: localhost only, for health checks. Everything else goes via Caddy."
    echo "WEB_BIND=127.0.0.1"
    echo "WEB_PORT=$PORT"
    echo
    echo "# Caddy sets CF-Connecting-IP from the real peer (see caddy/Caddyfile), so the sign-in"
    echo "# throttle and the activity log see each device, not Caddy. Single quotes: compose must"
    echo "# pass the nginx variable through literally."
    echo "CF_CONNECTING_IP='\$http_cf_connecting_ip'"
    echo "TRUST_PROXY=1"
    echo
    echo "# Kept on so a profile made with a password can still sign in; add a passkey in Settings."
    echo "PASSWORD_LOGIN=1" ;;
  tunnel)
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
    fi ;;
  esac
} > .env
chmod 600 .env
if [[ "$MODE" == https ]]; then
  # Its own file: .env is also the api container's env_file, and the token has no business there.
  ( umask 077; printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > caddy/caddy.env )
  mkdir -p caddy/data caddy/config
fi
echo "✓ wrote .env"

# ── validate ───────────────────────────────────────────────────────────────────────────────────
docker compose config -q || die "docker compose rejected the configuration — see the error above"
RENDERED="$(docker compose config)"
case "$MODE" in
  lan)
    grep -q "host_ip: $LAN_IP" <<<"$RENDERED" || die "port is not bound to $LAN_IP in the rendered config"
    grep -q 'CF_CONNECTING_IP: \$\$http' <<<"$RENDERED" \
      && die "CF_CONNECTING_IP is set — it must stay empty without a trusted proxy in front" ;;
  https)
    grep -q "host_ip: $LAN_IP" <<<"$RENDERED" || die "HTTPS is not bound to $LAN_IP in the rendered config"
    grep -q "host_ip: 127.0.0.1" <<<"$RENDERED" || die "the web container is not bound to 127.0.0.1"
    grep -q 'CF_CONNECTING_IP: \$\$http_cf_connecting_ip' <<<"$RENDERED" \
      || die "CF_CONNECTING_IP did not survive interpolation"
    grep -q "CF_API_TOKEN" <<<"$(sed -n '/^  api:/,/^  [a-z]*:$/p' <<<"$RENDERED")" \
      && die "the Cloudflare token ended up in the api container's environment" ;;
  tunnel)
    grep -q "host_ip: 127.0.0.1" <<<"$RENDERED" || die "port is not bound to 127.0.0.1 in the rendered config"
    grep -q 'CF_CONNECTING_IP: \$\$http_cf_connecting_ip' <<<"$RENDERED" \
      || die "CF_CONNECTING_IP did not survive interpolation" ;;
esac
echo "✓ docker compose config is valid"

# ── next steps ─────────────────────────────────────────────────────────────────────────────────
case "$MODE" in
lan) cat <<EOF

Next steps:

1. Build and start:

   docker compose up -d

2. Check from this machine:

   docker compose ps
   curl -fsS http://$LAN_IP:$PORT/api/health

3. Open on the phone (WireGuard on) or any device at home:

   http://$LAN_IP:$PORT

Plain http means: no passkeys, no push notifications, no installable/offline app, and the
password crosses your home Wi-Fi unencrypted. For all of that: scripts/homelab-setup.sh --https

EOF
;;
https) cat <<EOF

Next steps:

1. FRITZ!Box: allow a public name to point at a LAN address, or devices using the router's DNS
   get no answer for $HOST:

   Heimnetz → Netzwerk → Netzwerkeinstellungen → DNS-Rebind-Schutz → add: $HOST

2. Build and start (the first start takes a minute: Caddy asks Let's Encrypt for the certificate):

   docker compose up -d

3. Watch the certificate arrive ("certificate obtained successfully"):

   docker compose logs -f caddy

4. Check:

   curl -fsS https://$HOST$SUFFIX/api/health

5. Open on the phone (WireGuard on) or any device at home:

   https://$HOST$SUFFIX

   Sign in with your password, then Settings → Account → Passkeys → Add a passkey.

EOF
;;
tunnel) cat <<EOF

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
;;
esac
