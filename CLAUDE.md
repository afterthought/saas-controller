# SaaS Controller Module

Multi-cloud service orchestration with runtime + network provider abstraction for devenv.

## Architecture

Three independent axes:

- **Providers** (WHAT): Cloud platform adapters (zuplo, frontegg, datadog, secretspec)
- **Runtimes** (HOW): Process lifecycle managers (dev-manager-mcp, docker-compose, launchd)
- **Networks** (WHERE): URL exposure strategies (tailscale, localhost)

The dispatcher in `lib/helpers.nix` resolves the runtime + network for each service, then calls `runtime.mkScript` with network snippets injected.

## Key Files

```
devenv.nix              # Module options and config (imports everything)
lib/helpers.nix         # Task builders + runtime/network dispatcher
lib/dependencies.nix    # Dependency validation (circular detection)
lib/networks.nix        # Network strategies (tailscale, localhost)
runtimes/*.nix          # Process runtimes
providers/*.nix         # Cloud providers
scripts/*.mjs           # Helper scripts (frontegg registration)
```

## How dev-serve Works

1. `devenv.nix` iterates enabled services with `local` environment
2. For each service variant (e.g., api, docs), calls `helpers.mkDevServeScript`
3. `mkDevServeScript` resolves runtime (per-service or default) and network
4. Runtime's `mkScript` receives network snippets as bash strings
5. Generated script: start process -> set $PORT -> networkSetup -> networkPrintUrl -> tail logs -> networkCleanup on exit

## Config Resolution

```
service.runtime (per-service) ?? config.saas-controller.defaultRuntime -> runtimes.${name}
service.network (per-service) ?? config.saas-controller.defaultNetwork -> networks.${name}
```

## Extending

### New Provider

1. Copy `providers/TEMPLATE.nix`
2. Implement `provisionProject`, `deploy`, optionally `provision` (for hooks)
3. Register: `saas-controller.externalProviders.my-provider = ./my-provider.nix;`

### New Runtime

1. Copy `runtimes/TEMPLATE.nix`
2. Implement `mkScript` — must set `$PORT`, call network snippets, stream logs
3. Register: `saas-controller.externalRuntimes.my-runtime = ./my-runtime.nix;`

### New Network

Create a .nix file returning `{ name, setup, cleanup, printUrl }`:
- `setup`: bash snippet, called after `$PORT` is set, must set `$DEVSERVER_URL`
- `cleanup`: bash snippet, called in trap handler
- `printUrl`: bash snippet, echo the URL

Register: `saas-controller.externalNetworks.my-network = ./my-network.nix;`

## Task System

Tasks are input-based (environment passed as JSON at runtime):

```bash
DEVENV_TASK_INPUT='{"environment": "edge"}' devenv tasks run saas-deploy:my-service
```

Task chain: `saas-pre-deploy` -> `saas-deploy` -> `saas-post-deploy`

## Secrets

- **Control plane**: SaaS controller credentials (ZUPLO_API_KEY, FRONTEGG_*) via `environmentProfiles`
- **Data plane**: Service runtime secrets via `run.secretSource`

## Common Operations

```bash
sc up                              # Start all local services
sc deploy my-service -e edge       # Deploy with hooks
provision-projects                 # One-time setup
check-saas-controller-secrets      # Validate credentials
```
