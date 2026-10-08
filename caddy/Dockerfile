# Caddy with the Cloudflare DNS module, for HTTPS on a LAN-only address (docker-compose.https.yml).
# The certificate is issued through a DNS-01 challenge: Caddy writes a TXT record into the
# Cloudflare zone, Let's Encrypt reads it there — nothing has to reach this host from outside.
# xcaddy builds the Caddy version this builder image ships (CADDY_VERSION), so the binary and the
# runtime image below stay on the same minor.
FROM caddy:2.11-builder AS build
RUN xcaddy build --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11
COPY --from=build /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
