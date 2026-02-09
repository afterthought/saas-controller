## Why

The saas-controller duplicates docker-compose + tailscale sidecar lifecycle code across providers (zuplo, hello-world). Meanwhile, `__mac-nix` has its own `mkDockerService` for persistent docker services. Both systems need secret injection, tailscale networking, and compose lifecycle management. A generic `docker-compose` base provider in saas-controller would DRY up existing providers, enable zuplo to delegate its compose lifecycle, and make saas-controller capable enough that `__mac-nix` can migrate its docker services to it — replacing `mkDockerService` entirely.

Additionally, the secret composition model needs three layers: core secrets (tailscale), provider-contributed secrets (auto-included), and consumer-specified extras (per-instance). SA token swapping is needed so services can access client-scoped 1Password vaults, following the pattern established in `__mac-nix`.

## What Changes

- Extract a `docker-compose` base provider that owns the tailscale sidecar, serve-config generation, compose lifecycle (up/down/logs), error log dumps, and HTTPS URL printing
- Refactor `zuplo` provider to delegate compose lifecycle to the base provider, keeping only zuplo-specific logic (Dockerfile generation, npm workspace handling, Vite host fix, zuplo CLI commands)
- Refactor `hello-world` provider to delegate to the base provider
- Add `extraSecrets` option to the service secretspec submodule so consumers can declare additional secrets per-environment per-instance
- Auto-include provider-contributed `secretProfiles` when a service uses that provider (no manual listing required)
- Add `saToken` option to the secretspec submodule for SA token swapping before `secretspec run`
- Add `saTokensDir` controller-level option (default: `$HOME/.config/secretspec/sa-tokens`)
- Rewrite `sc up` secret injection from single re-exec to per-service isolation (each service gets its own SA token + secretspec context in a subshell)
- Add `toSASecretName` helper matching `__mac-nix` convention (`client-willdan` -> `OP_SA_CLIENT_WILLDAN`)
- The `docker-compose` provider accepts a pre-authored compose file and injects the tailscale sidecar via compose overlay (`-f original.yml -f tailscale-overlay.yml`)
- Persistent services (mac-nix migration) would use `sc deploy` with the docker-compose provider targeting launchd (future scope, not this change)

## Capabilities

### New Capabilities

- `docker-compose-base`: Generic compose lifecycle with tailscale sidecar injection — serve-config generation, compose overlay merging, up/down/logs, error handling, URL printing
- `secret-composition`: Three-layer secret merging (core + provider + consumer extras) with auto-include of provider profiles and per-instance `extraSecrets`
- `sa-token-swap`: Per-service SA token retrieval from macOS keyring before secretspec injection, following `__mac-nix` patterns

### Modified Capabilities

- (none — existing specs are for tailscale-worktree-isolation and secretspec-check-all, which are not modified by this change)

## Impact

- `providers/zuplo.nix`: Major refactor — delegates compose lifecycle to base provider, keeps only zuplo-specific logic (~60% code reduction in `up()`)
- `providers/hello-world.nix`: Major refactor — becomes a thin wrapper around base provider
- `devenv.nix`: New options (`saToken`, `extraSecrets`, `saTokensDir`), rewritten `sc up` secret injection (per-service instead of single re-exec), auto-include logic in `mkServiceSecretspecToml`
- `lib/docker-compose.nix` (new): Base provider extracted from shared code
- `__mac-nix` (future): Can migrate `mkDockerService` consumers to saas-controller's docker-compose provider

## Tracking

**Dex Epic**: `q3l8kojq`
