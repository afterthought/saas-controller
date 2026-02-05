## Tracking

Dex epic: `bz2ugx1p`

| Dex ID | Task Group |
|--------|-----------|
| vwzivcj8 | 1+5. Hostname derivation + tailnet discovery + sc up lifecycle (1.1-1.2, 5.1-5.4) |
| 30nl2r00 | 2+3+4. Tailscale sidecar in providers + SecretSpec (2.1-2.4, 3.1-3.2, 4.1) |
| 2b2nucgm | 6. Documentation (6.1-6.2) |
| hdlmck7j | 7. Verify (7.1-7.2) |

## 1. Hostname derivation and tailnet discovery

- [ ] 1.1 Add hostname derivation logic to `sc up` in devenv.nix: read `VK_WORKSPACE_ID`, compute `SLUG` (first 8 chars, fallback "local"), derive `HOSTNAME=sc-${SLUG}-${serviceName}`
- [ ] 1.2 Add tailnet discovery to `sc up`: assert `tailscale status` succeeds, read `TAILNET=$(tailscale status --json | jq -r '.MagicDNSSuffix')`, compute `FQDN=${HOSTNAME}.${TAILNET}`

## 2. Tailscale sidecar in zuplo provider

- [ ] 2.1 Add tailscale sidecar service to zuplo's generated docker-compose.yml: `tailscale/tailscale:latest`, env vars (`TS_HOSTNAME`, `TS_AUTHKEY`, `TS_EXTRA_ARGS`, `TS_SERVE_CONFIG`, `TS_STATE_DIR`, `TS_USERSPACE`), `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun]`, healthcheck (`tailscale status`, 2s/5s/10)
- [ ] 2.2 Change zuplo app containers (`zuplo-api`, `zuplo-docs`) to use `network_mode: service:tailscale` and `depends_on: tailscale: condition: service_healthy`
- [ ] 2.3 Generate `serve-config.json` in `.saas-controller/compose/${serviceName}/` mapping `:443` → `http://127.0.0.1:3000` and `:8443` → `http://127.0.0.1:3001`, mount into tailscale container at `/config/serve.json`
- [ ] 2.4 Set `ZUDOKU_PUBLIC_SERVER_URL=https://${FQDN}:443` on the `zuplo-docs` container environment

## 3. Tailscale sidecar in hello-world provider

- [ ] 3.1 Add tailscale sidecar service to hello-world's generated docker-compose.yml with same pattern as zuplo (single port mapping: `:443` → `http://127.0.0.1:3000`)
- [ ] 3.2 Change hello-world app container to use `network_mode: service:tailscale` and depend on tailscale healthcheck

## 4. OAuth client credentials via SecretSpec

- [ ] 4.1 Wrap provider `up()` compose invocation with SecretSpec to inject `TS_CLIENT_ID` and `TS_CLIENT_SECRET` from 1Password, or write a `.env` file in the compose directory with these values

## 5. Modify sc up lifecycle

- [ ] 5.1 Change `sc up` to use `docker compose up -d --wait` (detached with healthcheck wait) instead of foreground
- [ ] 5.2 Print `DEVSERVER_URL: https://${FQDN}:443` (and `:8443` for multi-variant services) after healthcheck passes
- [ ] 5.3 Start `docker compose logs -f` after URL printing for log streaming
- [ ] 5.4 Ensure trap handler runs `docker compose down` for all stacks on EXIT/INT/TERM

## 6. Documentation

- [ ] 6.1 Document one-time setup steps: Tailscale ACL tag (`tag:sc-dev`), OAuth client creation (Devices Read+Write scope, tagged `tag:sc-dev`), SecretSpec configuration for `TS_CLIENT_ID` and `TS_CLIENT_SECRET`
- [ ] 6.2 Update CLAUDE.md or README.md with tailscale setup prerequisites

## 7. Verify

- [ ] 7.1 Verify compose stack starts with tailscale sidecar and app containers come up after healthcheck
- [ ] 7.2 Verify HTTPS URLs are accessible on the tailnet at the derived hostname
