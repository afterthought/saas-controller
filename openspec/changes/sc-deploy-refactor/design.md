## Context

The saas-controller module has grown organically, accumulating configuration surface that either never got wired (releaseChannels), leaks implementation details (saToken hardcodes 1Password), or allows unbounded environment proliferation. Consumers define environments like `development`, `edge`, `main`, and `production` when only three are semantically meaningful: local, production, and preview. This creates secret sprawl — every service×environment combination needs its own set of secrets in 1Password.

The secretspec.toml generation writes to disk and then reads back, adding an unnecessary I/O step. The `sc deploy` default environment is `development` — a name that doesn't match any of the three canonical environments.

The current auth-related config has three overlapping concepts:
- **Per-secret `providers` list** in secretProfiles: tells secretspec which vault aliases supply a given secret
- **`secretspec_provider`** on environments/secret-exports: the alias used for export operations
- **`saToken`** on services: runtime SA token for docker-compose containers to authenticate to 1Password

## Goals / Non-Goals

**Goals:**
- Remove all unused option declarations (releaseChannels, datadog, externalSecretProfiles)
- Constrain environments to exactly three: `local`, `production`, `preview`
- Replace `saToken` with a generic `secretspec.auth` abstraction
- Stop writing secretspec.toml to disk — pass dynamically
- Add CLI tooling for secret environment setup, diff, and reconciliation
- Simplify `run.secretSource` redundancy

**Non-Goals:**
- Changing the three-layer secret composition engine (it works well)
- Changing the provider plugin interface (beyond saToken removal from docker-compose)
- Adding new secret backends — just abstract so they're possible
- Redesigning the deploy task pipeline
- Implementing secret inheritance (preview→production) — that's a future enhancement

## Decisions

### 1. Remove releaseChannels entirely

The releaseChannels option (lines 114-307 of devenv.nix) defines stable/canary/beta/sandbox channels with autodeploy policies, version patterns, audience filtering, rollback config, and deployment policies. None of this is referenced by any CLI command, helper function, or provider. It's dead code that adds ~190 lines of complexity.

**Alternatives considered:**
- Keep but mark deprecated: Rejected — unused code should be removed, not deprecated. Can be re-added when actually needed.

### 2. Constrain environments to enum of three

Replace the freeform `lib.types.attrsOf` environment definition with a constrained set:

```nix
environments = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule { ... });
  # Validation: keys must be one of "local", "production", "preview"
};
```

Add an assertion that environment keys are a subset of `["local" "production" "preview"]`.

The `sc deploy` default environment changes from `"development"` to `"production"`.

Fields per environment that survive the cut:
- `enable` — keep
- `providerEnvConfig` — keep (provider-specific overrides)
- `secretspec_provider` — keep (used by secret export hooks)
- `skipSecretExport` — keep
- `branch` — remove (not meaningfully used; CI determines branch)
- `autodeploy` — remove (CI concern, not saas-controller's domain)
- `branchPattern` — remove (only relevant if supporting arbitrary environments)

**Alternatives considered:**
- Soft validation (warn on non-standard names): Rejected — soft warnings get ignored. Hard constraint prevents sprawl.
- Keep `branch` for CI integration: Rejected — CI pipelines know their own branches. This was configuration that nobody reads.

### 3. Replace saToken with secretspec.auth

The current `saToken` field assumes 1Password and hardcodes the `OP_SA_` prefix naming convention. Replace with:

```nix
secretspec = {
  auth = {
    provider = lib.mkOption {
      type = lib.types.str;
      description = "SecretSpec provider alias for runtime secret authentication";
      example = "client-willdan";
    };
  };
  # environments, tags remain as-is
};
```

This replaces **both** `saToken` and simplifies the mental model. The `auth.provider` value is a secretspec provider alias — the same kind of alias used in per-secret `providers` lists. The docker-compose provider uses this to authenticate to the secret backend at runtime, without knowing it's 1Password.

The per-secret `providers` lists in secretProfiles remain unchanged — those are already generic (they reference secretspec aliases, not 1Password-specific concepts).

The `toSASecretName` helper and the `OP_SA_*` keyring convention move into the secretspec tool itself, where they belong. saas-controller just passes the alias; secretspec resolves it.

**Alternatives considered:**
- Keep saToken but rename: Rejected — the problem isn't the name, it's that saas-controller is encoding 1Password's auth mechanism instead of delegating to secretspec.
- Full provider abstraction with pluggable backends: Rejected as non-goal — we just need to stop hardcoding 1Password. The alias already delegates.

### 4. Dynamic secretspec.toml — pipe instead of file

Currently:
1. Nix generates TOML content as a string
2. Shell script writes it to `.saas-controller/secretspec/<svc>/secretspec.toml`
3. `secretspec run` reads it from disk

Replace with passing the TOML content directly. The approach depends on what secretspec CLI supports:
- **Option A**: `secretspec run --config <(echo "$TOML_CONTENT")` (process substitution)
- **Option B**: `echo "$TOML_CONTENT" | secretspec run --config -` (stdin)
- **Option C**: `SECRETSPEC_CONFIG="$TOML_CONTENT" secretspec run` (environment variable)

The `generateAllServiceSecretspecs` script is removed. Each `sc up` and deploy task inlines the TOML content directly from a Nix-generated bash variable.

The `sc check-secrets` and `sc secret-status` commands still need access to the TOML structure, but they're computed at Nix eval time already — they don't need disk files.

**Alternatives considered:**
- Keep writing to disk but use a temp dir: Rejected — still an unnecessary I/O step. The content is already in memory.
- Write to nix store: Rejected — changes on every config edit, clutters the store.

### 5. Secret reconciliation tooling

Three new `sc` subcommands:

**`sc setup-env <environment>`**
- Iterates all services with secretspec config for the given environment
- For each secret: checks if it exists in the provider, prompts to set if missing
- Groups by provider alias so you're not switching contexts constantly
- Output: summary of secrets set vs skipped

**`sc diff-secrets <env1> <env2>`**
- Shows which secrets differ between two environments
- Columns: secret name, env1 status (set/missing/default), env2 status
- Highlights secrets that are set in one but missing in the other

**`sc reconcile-secrets [--environment <env>]`**
- For each service/environment: shows all secrets with their status
- Status: set (value exists), missing (required but absent), default (using default value), optional-missing (not required, not set)
- Highlights anything that needs attention
- This is an enhanced version of `check-secrets` that also covers optional secrets needing environment-specific overrides

**Alternatives considered:**
- Build into existing `check-secrets`: Rejected — check-secrets has a clear purpose (fail on missing required). Reconciliation is an interactive exploration tool.

### 6. Remove datadog service option

The datadog option (lines 683-719) defines enable, syncOn, environments, and entityMapping fields. In all known consumers it's set to `null`. The datadog provider itself can remain available for re-integration later, but the per-service option declaration adds dead config surface.

**Alternatives considered:**
- Keep as optional: It already is optional (default null), but it adds 37 lines of option declarations that no consumer uses. Remove and re-add with a cleaner interface when needed.

### 7. Consolidate run.secretSource

Currently both `run.secretSource` (global default) and `run.environments.<env>.secretSource` (per-env override) exist. With only three environments, this two-level fallback adds complexity for marginal benefit.

Replace with a single `run.secretSource` field — if different environments need different sources, use the per-environment `secretspec_provider` which already exists.

## Risks / Trade-offs

**[Breaking changes for consumers]** → Provide clear migration docs. The environment rename (development/edge/main → production) and saToken → auth migration need documented steps. Include migration examples in EXTENDING.md and CHANGELOG.

**[secretspec CLI may not support stdin/process-sub for config]** → Spike this before committing to decision 4. If secretspec requires a file path, use a temp file with cleanup instead of the current persistent file.

**[Removing releaseChannels precludes future channel-based deployments]** → Acceptable. If channels are needed later, they'll be designed with actual CLI/provider wiring from the start, informed by real requirements.

**[Three-environment constraint may be too rigid for some consumers]** → The constraint can be loosened later. Starting rigid and loosening is safer than starting loose and trying to tighten. Preview environments with branch-specific names (preview-feature-x) are handled by the preview environment with `branchPattern`-like config, not by creating new environments.

## Open Questions

1. **secretspec CLI capabilities**: Does `secretspec run` support `--config -` (stdin) or `--config <path>` with process substitution? This determines the approach for decision 4.
2. **Preview environment branching**: How should preview environments reference their branch? The current `branchPattern` field is being removed — does the preview environment need a replacement mechanism, or is branch info purely a CI concern?
3. **Secret reconciliation interactivity**: Should `sc setup-env` be interactive (prompt for values) or just report what's missing and let the user set values via 1Password/secretspec directly?
