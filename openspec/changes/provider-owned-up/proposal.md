## Why

The runtime/network abstraction (providers × runtimes × networks) was a premature generalization. Providers need to own their full local dev lifecycle — Zuplo runs two related processes (API gateway + docs portal) as a composite, but the current system dispatches each variant independently through a generic runtime, losing the composite relationship. Collapsing runtimes and networks into provider-owned `up()` with docker-compose simplifies the architecture and enables composite services.

## What Changes

- **BREAKING**: Remove the entire runtime axis (`runtimes/` directory, `defaultRuntime`, `externalRuntimes`, per-service `runtime` option)
- **BREAKING**: Remove the entire network axis (`lib/networks.nix`, `defaultNetwork`, `externalNetworks`, per-service `network` option)
- **BREAKING**: Remove `localVariants` from the provider interface — replaced by `up()`
- Remove `mkDevServeScript`, `resolveRuntime`, `resolveNetwork` from `lib/helpers.nix`
- Remove dev-serve script generation from `devenv.nix` config section
- Add `up(serviceName, service)` to the provider contract — a bash script string that generates docker-compose files in `.saas-controller/compose/${serviceName}/`, runs `docker compose up` foreground, and cleans up on exit
- Implement `up()` for zuplo provider (two-service compose: api + docs)
- Implement `up()` for hello-world provider (single-service compose)
- Rewrite `sc up` to call `provider.up` directly instead of backgrounding per-variant dev-serve scripts

## Capabilities

### New Capabilities
- `provider-up`: Provider-owned local development lifecycle via docker-compose — providers define their own `up()` function that generates compose files, starts containers, streams logs, and cleans up on exit

### Modified Capabilities

## Impact

- **devenv.nix**: Remove ~100 lines of runtime/network options and assertions; rewrite `sc up` command to call provider.up
- **lib/helpers.nix**: Remove `mkDevServeScript`, `resolveRuntime`, `resolveNetwork` (~30 lines); deploy task builders unchanged
- **providers/zuplo.nix**: Remove `localVariants`, add `up()` with two-service docker-compose
- **providers/hello-world.nix**: Remove `localVariants`, add `up()` with single-service docker-compose
- **providers/TEMPLATE.nix**: Update interface documentation
- **EXTENDING.md**: Rewrite runtime/network sections, update provider guide for `up()` interface
- **Deleted files**: `runtimes/dev-manager-mcp.nix`, `runtimes/docker-compose.nix`, `runtimes/launchd.nix`, `runtimes/TEMPLATE.nix`, `lib/networks.nix`
- **No impact** on deploy pipeline, secret management, dependency validation, or VibeKanban integration

## Tracking

Dex epic: `51kuid7q`
