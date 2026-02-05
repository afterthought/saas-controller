## Context

SaaS Controller currently dispatches local dev servers through three orthogonal axes: providers define `localVariants` (what to run), runtimes manage process lifecycle (`dev-manager-mcp`, `docker-compose`, `launchd`), and networks handle URL exposure (`tailscale`, `localhost`). The runtime and network axes were premature abstractions — only `dev-manager-mcp` runtime and `tailscale`/`localhost` networks are actually used. The Zuplo provider returns two independent variants (api, docs) that get dispatched separately, losing their composite relationship.

The deploy pipeline (tasks, hooks, secret management, dependency validation) is unaffected by this change.

## Goals / Non-Goals

**Goals:**
- Providers own their full local dev lifecycle via an `up(serviceName, service)` function
- Use docker-compose as the standard process orchestrator for local dev
- Zuplo provider can express its api + docs processes as a single composite service
- `sc up` remains the entry point but calls provider.up directly
- Generated compose files live in `.saas-controller/compose/${serviceName}/`

**Non-Goals:**
- No tailscale sidecar containers (next change: `tailscale-worktree-isolation`)
- No worktree-derived hostnames
- No OAuth client setup
- No changes to deploy pipeline, secret management, or dependency validation
- No changes to VibeKanban integration

## Decisions

### 1. Provider-owned `up()` replaces runtime/network dispatch

**Decision**: Each provider implements `up = serviceName: service: ''...''` returning a bash script string that handles the full local dev lifecycle.

**Rationale**: Providers understand their own process topology. Zuplo knows it needs api + docs running together. A generic runtime can't express composite relationships. The `up()` pattern matches the existing `deploy()` pattern — a bash script string evaluated in a Nix context.

**Alternative considered**: Keep runtimes but make them composite-aware. Rejected — adds complexity to the runtime interface without benefit, since each provider's local dev needs are unique.

### 2. Docker-compose as the standard orchestrator

**Decision**: Provider `up()` functions generate `docker-compose.yml` and `Dockerfile` in `.saas-controller/compose/${serviceName}/`, then run `docker compose up`.

**Rationale**: Docker-compose handles process lifecycle, log interleaving, dependency ordering, and cleanup natively. It's the simplest way to express multi-process services. Providers generate compose files rather than importing a shared one, keeping each provider self-contained.

**Alternative considered**: Direct process spawning with bash job control. Rejected — reimplements what docker-compose already does, and makes the tailscale sidecar (next change) harder to add.

### 3. Hardcoded localhost URLs (no network axis)

**Decision**: Remove the network abstraction entirely. Providers hardcode `http://localhost:${PORT}` URLs. The tailscale sidecar pattern (next change) will be added to compose files directly, not through a network abstraction.

**Rationale**: The network axis only had two implementations (tailscale, localhost), and the tailscale integration will become a compose sidecar container — a fundamentally different pattern that doesn't fit the bash-snippet network interface. Localhost is the correct default for this intermediate step.

### 4. Compose file generation pattern

**Decision**: Each `up()` writes files using heredocs in bash, not Nix-generated YAML.

**Rationale**: Compose files need runtime values (paths, ports). Bash heredocs with Nix string interpolation (`${config.git.root}`) is the established pattern in this codebase (see deploy scripts). Keeps compose files as an implementation detail of the provider.

### 5. sc up calls provider.up sequentially per service, with parallel compose stacks

**Decision**: `sc up` iterates enabled services, starts each provider's compose stack in the background, then waits. Each stack's logs stream to stdout via `docker compose logs -f`.

**Rationale**: Simple and matches current behavior (parallel dev-serve scripts with `wait`). Docker-compose handles per-stack process management internally.

## Risks / Trade-offs

**[Provider duplication]** → Each provider writes its own compose generation code, leading to some boilerplate duplication across providers. Acceptable at current scale (2 providers); can extract shared helpers if pattern stabilizes.

**[Docker dependency]** → Requires Docker to be installed and running for `sc up`. Previously `dev-manager-mcp` used mcporter (Node.js). Mitigated: Docker is already a standard devenv dependency for most teams.

**[Intermediate localhost state]** → Between this change and `tailscale-worktree-isolation`, services are only accessible on localhost. This is a deliberate stepping stone — the tailscale sidecar will be added to compose files in the next change.

**[Breaking change for custom runtimes/networks]** → Any external runtimes or networks registered via `externalRuntimes`/`externalNetworks` will break. Mitigated: no known external consumers exist.
