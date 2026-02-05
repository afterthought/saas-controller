## Why

After `provider-owned-up` lands, `sc up` runs services via docker-compose on localhost. Multiple VibeKanban worktrees running `sc up` on the same machine will collide on ports and localhost. The docs portal (Zudoku) needs a deterministic URL for the API gateway (`ZUDOKU_PUBLIC_SERVER_URL`) that works across worktrees. Each worktree needs a unique, deterministic hostname on the tailnet so services run concurrently without collision, with HTTPS and valid certs handled by Tailscale.

## What Changes

- Add a tailscale sidecar container to each provider's docker-compose.yml for tailnet identity
- Derive deterministic hostnames from VibeKanban workspace ID: `sc-${SLUG}-${serviceName}` where SLUG is the first 8 chars of `VK_WORKSPACE_ID` (fallback: "local")
- Generate `serve-config.json` for tailscale serve — maps HTTPS ports to internal HTTP services (`:443` → api on `:3000`, `:8443` → docs on `:3001`)
- All service containers use `network_mode: service:tailscale` to share the sidecar's network namespace
- Inject OAuth client credentials (`TS_CLIENT_ID`, `TS_CLIENT_SECRET`) via SecretSpec from 1Password
- Modify `sc up` to read `VK_WORKSPACE_ID`, assert tailscale is running on host, use `docker compose up -d --wait` for healthcheck, then print `DEVSERVER_URL` with HTTPS tailnet FQDNs
- Set `ZUDOKU_PUBLIC_SERVER_URL` to `https://${FQDN}:443` at compose generation time for deterministic cross-service discovery

## Capabilities

### New Capabilities
- `tailscale-sidecar`: Tailscale sidecar container integration for docker-compose stacks — ephemeral nodes with worktree-derived hostnames, serve config for HTTPS routing, and automatic cleanup
- `worktree-hostname`: Deterministic hostname derivation from VibeKanban workspace ID for multi-worktree isolation on the tailnet

### Modified Capabilities

## Impact

- **providers/zuplo.nix**: Add tailscale sidecar to compose, generate serve-config.json, set `ZUDOKU_PUBLIC_SERVER_URL` dynamically, use `network_mode: service:tailscale` on app containers
- **providers/hello-world.nix**: Optionally add tailscale sidecar (or keep localhost-only for simple testing)
- **devenv.nix**: Modify `sc up` for tailnet discovery, workspace slug derivation, healthcheck wait, HTTPS URL printing
- **Documentation**: One-time setup steps for Tailscale ACL tags, OAuth client creation, SecretSpec configuration
- **No impact** on deploy pipeline, provider `up()` contract (already exists), or VibeKanban

## Tracking

Dex epic: `bz2ugx1p`
