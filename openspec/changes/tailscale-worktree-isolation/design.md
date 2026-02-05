## Context

After `provider-owned-up`, each provider's `up()` generates a docker-compose.yml and runs `docker compose up`. Services are accessible only on localhost with hardcoded ports (3000 for api, 3001 for docs). VibeKanban launches multiple worktrees concurrently on the same machine, each calling `sc up`. Without unique network identities, these worktrees collide on ports and can't cross-reference each other's services.

VibeKanban provides `VK_WORKSPACE_ID` (a UUID) as an environment variable in each worktree session. Tailscale's ephemeral nodes with OAuth clients provide automatic node creation and cleanup. Tailscale serve provides HTTPS termination with valid certs.

## Goals / Non-Goals

**Goals:**
- Each worktree gets a unique, deterministic tailnet hostname derived from `VK_WORKSPACE_ID`
- Services within a compose stack share a network namespace via the tailscale sidecar
- HTTPS with valid certs on the tailnet (tailscale serve handles TLS)
- `ZUDOKU_PUBLIC_SERVER_URL` computed at compose generation time — no runtime discovery
- Ephemeral nodes auto-remove when containers stop
- Graceful fallback to "local" slug when `VK_WORKSPACE_ID` is not set

**Non-Goals:**
- No changes to the deploy pipeline
- No changes to the provider `up()` contract (this adds to compose files, doesn't change the interface)
- No multi-service routing within a single sidecar (one sidecar per compose stack)
- No changes to VibeKanban itself

## Decisions

### 1. Tailscale sidecar per compose stack

**Decision**: Each provider's compose stack includes a `tailscale` service using `tailscale/tailscale:latest`. All application containers use `network_mode: service:tailscale` to share its network namespace.

**Rationale**: The sidecar pattern is Tailscale's recommended approach for containers. Sharing the network namespace means app containers bind to `127.0.0.1:PORT` and the tailscale sidecar routes external traffic to them via serve config. No port mapping or host networking needed.

**Alternative considered**: Host-level `tailscale serve` (the old network axis approach). Rejected — requires host tailscale reconfiguration per worktree, can't isolate per-worktree, and conflicts with the containerized approach from `provider-owned-up`.

### 2. Hostname derivation from VK_WORKSPACE_ID

**Decision**: `SLUG = first 8 chars of VK_WORKSPACE_ID`. `HOSTNAME = sc-${SLUG}-${serviceName}`. Fallback `SLUG = "local"` when `VK_WORKSPACE_ID` is unset.

**Rationale**: VK_WORKSPACE_ID is a UUID (hex chars), so the first 8 chars are DNS-safe and provide sufficient uniqueness across concurrent worktrees. The `sc-` prefix identifies saas-controller nodes on the tailnet. The full hostname is well under the 63-char DNS label limit. The "local" fallback enables `sc up` outside VibeKanban sessions.

**Alternative considered**: Hash of worktree path. Rejected — VK_WORKSPACE_ID is already provided and stable, no need to derive from filesystem state.

### 3. Tailscale serve config for HTTPS routing

**Decision**: Generate `serve-config.json` alongside `docker-compose.yml`. Mount it into the tailscale container at `/config/serve.json`. Configure `TS_SERVE_CONFIG` to use it. Map `:443` → `http://127.0.0.1:3000` (api) and `:8443` → `http://127.0.0.1:3001` (docs).

**Rationale**: Tailscale serve provides automatic HTTPS with valid certs on the tailnet. Using a static config file (vs `tailscale serve` CLI commands) is more reliable in containers and avoids race conditions during startup. Port 443 for the primary service and 8443 for the secondary keeps a simple convention.

**Alternative considered**: Tailscale funnel (public internet). Rejected — dev services should only be accessible on the tailnet, not the public internet.

### 4. OAuth client credentials via SecretSpec

**Decision**: `TS_CLIENT_ID` and `TS_CLIENT_SECRET` stored in 1Password. Injected into the compose environment via SecretSpec (`secretspec run --provider <source> --profile local --`). The OAuth client is configured with Devices Read+Write scope and tagged `tag:sc-dev`. Nodes created with `?ephemeral=true` on the auth key auto-remove after disconnect.

**Rationale**: Reuses the existing SecretSpec infrastructure for secret injection. OAuth clients (vs pre-auth keys) support programmatic node creation without expiring keys. Ephemeral nodes ensure automatic cleanup when compose stacks stop.

### 5. Healthcheck-gated URL printing

**Decision**: `sc up` uses `docker compose up -d --wait` to start the stack and wait for the tailscale container's healthcheck (`tailscale status`, 2s interval, 5s timeout, 10 retries). URLs are printed only after the healthcheck passes. Log streaming starts with `docker compose logs -f` after URLs are printed.

**Rationale**: The tailscale node needs time to authenticate and register on the tailnet. Printing URLs before the node is ready would give users broken links. The `--wait` flag leverages compose's built-in healthcheck support rather than polling from bash.

### 6. Tailnet suffix read from host tailscale

**Decision**: `TAILNET=$(tailscale status --json | jq -r '.MagicDNSSuffix')` is read from the host's tailscale installation before starting compose stacks. This is used to compute FQDNs for URL printing.

**Rationale**: The MagicDNS suffix is a property of the tailnet, not the ephemeral node. Reading it from the host avoids waiting for the sidecar to start. The host must already be on the tailnet for the sidecar to function.

## Risks / Trade-offs

**[Docker + Tailscale dependency]** → Requires both Docker and Tailscale installed and running on the host. Mitigated: both are standard dev tools, and `sc up` asserts tailscale is running before starting stacks.

**[OAuth client setup]** → One-time manual setup required (ACL tags, OAuth client, SecretSpec entry). Mitigated: documented in setup guide with step-by-step instructions.

**[Ephemeral node limits]** → Tailscale has limits on ephemeral nodes per tailnet. At typical dev scale (2-5 concurrent worktrees × 1-2 services), this is not a concern.

**[Port convention rigidity]** → Hardcoded `:443` and `:8443` mapping means all providers must use the same port convention. Acceptable: providers already control their internal ports, and the serve config maps external → internal.

**[Fallback mode limited]** → When `VK_WORKSPACE_ID` is unset, the "local" slug means only one non-VibeKanban session can run at a time (hostname collision). Acceptable: the primary use case is VibeKanban worktrees.
