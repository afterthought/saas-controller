## Context

saas-controller providers (zuplo, hello-world) duplicate ~80 lines of identical docker-compose + tailscale sidecar lifecycle code. The `__mac-nix` project has a parallel `mkDockerService` library for persistent docker services. Both systems need compose lifecycle, secret injection, and tailscale networking. Unifying under a single base provider in saas-controller enables code reuse and positions saas-controller as the home for all docker-compose service orchestration.

The current secret model has two layers (controller profiles + provider profiles) but lacks per-instance extensibility and SA token scoping. Services that need client-specific 1Password vaults can't access them with the inherited coordinator SA token.

## Goals / Non-Goals

**Goals:**
- Extract shared compose lifecycle into a reusable `lib/docker-compose.nix` library
- Enable zuplo and hello-world providers to delegate compose lifecycle to the library
- Create a `docker-compose` provider for pre-authored compose files (mac-nix migration path)
- Add `extraSecrets` for per-instance secret extension
- Auto-include provider secret profiles when a service uses that provider
- Add per-service SA token swapping with keyring retrieval
- Make the generated secretspec.toml merge all three secret layers

**Non-Goals:**
- Converting providers from plain attrsets to NixOS modules (collection glue stays in devenv.nix)
- Implementing the `sc deploy` launchd mode (future scope)
- Migrating mac-nix services in this change (this creates the capability)
- Changing the deploy pipeline (pre/post hooks, task system)

## Decisions

### 1. Shared library (lib/docker-compose.nix) rather than a base provider

Extract the tailscale sidecar and compose lifecycle into a library of Nix functions in `lib/docker-compose.nix`, not as a provider. Providers call library functions to build their compose stacks.

The library exports:
- `mkTailscaleSidecar`: Returns the YAML snippet for the tailscale sidecar service
- `mkServeConfig`: Generates serve-config.json from a list of `{ port, upstream }` entries
- `mkComposeLifecycle`: The up/down/logs/error-dump/cleanup lifecycle shell script, given a compose file path and service name

Providers compose these building blocks. The `docker-compose` provider uses them directly. Zuplo calls them after generating its own Dockerfile and app services.

**Alternatives considered:**
- Provider inheritance (zuplo extends docker-compose): Nix doesn't have OOP inheritance. Attrset merging is fragile for multi-line bash strings.
- Single monolithic provider with feature flags: Gets messy — zuplo's npm workspace handling, Dockerfile generation, and Vite workarounds don't belong in a generic provider.

### 2. Compose overlay for the docker-compose provider

The `docker-compose` provider injects the tailscale sidecar via Docker Compose's native multi-file merge: `docker compose -f original.yml -f tailscale-overlay.yml up`. The overlay adds the tailscale service and overrides `network_mode` on app services.

This means consumers bring their own `docker-compose.yml` (hand-authored or generated) and the provider layers tailscale on top without modifying the original file.

**Alternatives considered:**
- Parsing YAML with `yq` to inject sidecar: Fragile, requires yq dependency, may break with complex compose features.
- Requiring consumers to include tailscale in their compose file: Defeats the purpose — tailscale injection should be transparent.

### 3. Per-instance `extraSecrets` on the secretspec environment submodule

Add `secrets` (renamed from `extraSecrets` for brevity) as an attrset on each environment within the secretspec submodule:

```nix
secretspec = {
  saToken = "client-willdan";
  environments.local = {
    serviceProfiles = [ "tailscale" ];
    secrets = {
      STRIPE_API_KEY = { description = "..."; providers = [ "client-willdan" ]; };
    };
  };
};
```

These merge into the generated TOML alongside profile secrets. Provider profiles are auto-included (Decision 4), so the consumer only lists cross-cutting profiles (like tailscale) and instance-specific extras.

**Alternatives considered:**
- A separate `extraProfiles` option: Adds indirection — the consumer would need to define a named profile and then reference it. Direct inline secrets are simpler.

### 4. Auto-include provider profiles by looking up `providers.${service.provider}.secretProfiles`

When generating the secretspec TOML for a service, prepend the provider's profile names to the environment's `serviceProfiles` list. This happens in `mkServiceSecretspecToml` by inspecting the provider object.

Result: a service with `provider = "zuplo"` automatically gets the `zuplo` secret profile without listing it in `serviceProfiles`. Explicit listing is harmless (deduped via `lib.unique`).

**Alternatives considered:**
- Making providers NixOS modules that set `config.saas-controller.secretProfiles`: Would require a provider system refactor. The current approach achieves the same result with a 3-line change in `mkServiceSecretspecToml`.

### 5. Per-service secret injection instead of single re-exec

Replace the current `sc up` pattern (one `exec secretspec run` that re-launches the whole command) with per-service injection inside each parallel subshell:

```bash
(
  # SA token swap (if configured)
  export OP_SERVICE_ACCOUNT_TOKEN="$(cd $saTokensDir && secretspec get --provider keyring --profile default $tokenName)"

  # Inject secrets and run
  cd $secretspecDir
  secretspec run --profile "$ENVIRONMENT" -- bash -c "$upScript"
) &
```

Each service runs in its own subshell with its own `OP_SERVICE_ACCOUNT_TOKEN`. This is necessary because different services may need different SA tokens (e.g., one for client-willdan, another for client-integral).

**Alternatives considered:**
- Keeping the single re-exec with a "lowest common denominator" SA token: Can't work — one SA token can't access all client vaults.
- Running `secretspec run` once per SA token, grouping services by token: Adds complexity for marginal benefit. The per-service approach is simpler and handles the general case.

### 6. `toSASecretName` matches `__mac-nix` exactly

The naming convention `client-willdan` -> `OP_SA_CLIENT_WILLDAN` uses the same transform as `__mac-nix/modules/home/1password.nix:35`:

```nix
toSASecretName = name: "OP_SA_${lib.toUpper (builtins.replaceStrings ["-"] ["_"] name)}";
```

SA tokens are stored in the macOS keyring at `$HOME/.config/secretspec/sa-tokens/` (managed by `__mac-nix`). The `saTokensDir` option allows overriding for CI or alternative setups.

### 7. The `docker-compose` provider's `providerConfig` schema

```nix
providerConfig = {
  path = "services/miniflux";           # directory with docker-compose.yml
  composeFile = "docker-compose.yml";   # default, can override
  tailscale = [                         # serve entries (port -> upstream)
    { port = 443; upstream = "http://127.0.0.1:8080"; }
  ];
};
```

The provider reads the compose file, generates a tailscale overlay, and runs both via `docker compose -f ... -f ... up`.

## Risks / Trade-offs

- **`secretspec run ... -- bash -c <large-script>`**: Provider `up()` scripts can be 100+ lines. Passing via `bash -c` requires careful escaping. `lib.escapeShellArg` handles this, but trap handlers and nested subshells within the script need testing. Mitigation: test with the zuplo provider's full up() script.

- **Compose overlay `network_mode` override**: The overlay needs to know which services in the original compose file should get `network_mode: service:tailscale`. The provider could auto-detect all non-tailscale services, or require explicit configuration. Decision: auto-detect by listing all services in the original YAML and applying `network_mode` to each.

- **SA token keyring not populated**: If `store-sa-tokens` hasn't been run, `secretspec get --provider keyring` will fail. Mitigation: clear error message with remediation instructions, matching `__mac-nix` pattern.

- **Breaking change risk for zuplo refactor**: Zuplo's `up()` generates compose files dynamically. Extracting the tailscale sidecar into the library means zuplo generates only its app services, then calls the library to wrap with tailscale. The generated compose files will be structurally identical — verify by diffing before/after.

## Open Questions

- Should the `docker-compose` provider support `docker compose watch` mode for live-reloading pre-authored services? (Not needed for MVP)
- Should `sc deploy` with the docker-compose provider support launchd plist generation? (Explicitly deferred — future scope)
