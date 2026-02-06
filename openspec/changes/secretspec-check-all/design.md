## Context

SaaS Controller manages secrets at two levels: control plane (controller credentials like ZUPLO_API_KEY, FRONTEGG_*) and data plane (per-service runtime secrets). The control plane has three validation scripts (`check-saas-controller-secrets`, `check-dev-saas-controller`, `check-prod-saas-controller`) that only validate the controller's own profiles. Per-service secretspec projects have no validation mechanism.

The `sc up` command requires `TS_CLIENT_SECRET` for tailscale sidecar containers but validates this with a raw bash `[ -z ]` check rather than secretspec. Services that need additional secrets for local dev (API keys, database URLs) have no pre-flight validation at all.

The secretspec fork (afterthought/secretspec at commit 8744fa9) supports `required = false` on individual secrets, `--provider` and `--profile` flags for check/run/export, and `--include`/`--exclude` filter patterns.

## Goals / Non-Goals

**Goals:**
- Unified `sc check-secrets` command that validates controller + all registered service secretspec projects in one pass
- Per-service `secretspec` option in the service submodule so services opt into validation
- Tag-based filtering so `sc check-secrets --tag tailscale` checks only relevant services
- Static `secretspec.toml` for test-gateway example with tailscale vars (TS_CLIENT_SECRET required, TS_CLIENT_ID and SC_TAILNET optional)
- Deprecation path from old check scripts to new unified command

**Non-Goals:**
- Auto-generation of secretspec.toml from nix config (services maintain their own static TOML files)
- Auto-extends / tag-based composition (composing shared secret sets into generated TOMLs)
- Pre-flight gate in `sc up` (can be added as a follow-up)
- enterShell integration (checks are on-demand only)
- Changes to the secretspec-export provider or include/exclude pattern system

## Decisions

### Use existing service registry instead of separate secretspecDirs option

The mac-nix project uses a standalone `custom.secretspecDirs` list. In saas-controller, services are already registered via `config.saas-controller.services` with `providerConfig.path` pointing to their source directory. Adding a parallel registry would risk drift.

**Decision**: Derive check targets from the service registry. Services with `secretspec != null` participate in checks. The secretspec path defaults to `providerConfig.path`.

**Alternative considered**: Separate `secretspecDirs` option (mac-nix pattern). Rejected because it duplicates service registration and could get out of sync.

### Static secretspec.toml files, not generated

Services maintain their own `secretspec.toml` checked into the repo. The controller's dynamic generation (`generateControllerSecretspecCmd`) already exists and continues unchanged.

**Decision**: No `generate = true` mechanism. Each service that needs validation creates a static `secretspec.toml` in its directory.

**Alternative considered**: Auto-generation from nix config with tag-based composition via `secretspecTagSources`. Rejected because it adds complexity without a concrete use case—if we later find duplicated declarations across many services, we can add composition then.

### Tags for filtering only, not composition

Tags on the service secretspec config are used exclusively for `--tag` filtering in `sc check-secrets`. They do not affect TOML generation or secret inheritance.

**Decision**: Tags are metadata labels for check-time filtering.

**Alternative considered**: Tags driving `extends` in generated TOML. Deferred—filtering is the immediate need.

### Null checkProvider defaults to secretspec's own resolution

When `checkProvider` is null, `sc check-secrets` runs `secretspec check --profile <p>` without `--provider`, letting secretspec resolve the provider from its global config or the TOML's `providers` field. This avoids hardcoding "onepassword" everywhere.

**Alternative considered**: Default to "onepassword". Rejected because it couples the nix module to a specific backend.

### Deprecation, not removal, of old scripts

The three existing check scripts continue to work but print a deprecation notice pointing to `sc check-secrets`.

**Decision**: Soft deprecation. Scripts still function.

## Risks / Trade-offs

- **[Risk: Secrets check fails in CI without provider]** Services using 1Password require `OP_SERVICE_ACCOUNT_TOKEN` or biometric unlock. CI environments may not have these. → **Mitigation**: `sc check-secrets` exits cleanly with a warning when the provider is unavailable, rather than hard-failing. Individual services can set `checkProvider` to an available provider.

- **[Risk: Tag filtering is too coarse]** Tags are simple strings with AND semantics within `--tag`. No OR/NOT support. → **Mitigation**: Keep it simple for now. `--service <name>` provides precise targeting. Complex filtering can be added if needed.

- **[Trade-off: No enterShell integration]** Secrets are not validated automatically when entering the devenv shell. Developers must explicitly run `sc check-secrets`. → **Rationale**: Automatic validation on shell entry would slow down the common case and may fail in environments without provider access. On-demand is the right default.
