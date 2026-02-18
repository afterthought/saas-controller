## Context

Every secret in saas-controller's generated `secretspec.toml` files carries an explicit `providers = ["saas-controller"]` list. This is repeated on every secret, across every profile, across every service. SecretSpec supports `[profiles.<env>.defaults]` sections with a `providers` key that secrets inherit unless they override. saas-controller does not use this feature today.

The saas-controller generates TOML in `mkServiceSecretspecToml` (devenv.nix ~line 602), serializing each secret via `mkSecretToml` (line 584). The `mkSecretToml` function already skips the `providers` attribute when the list is empty — so the per-secret side requires no changes.

The three-layer secret composition (provider profiles > controller profiles > inline secrets) is duplicated across several code paths: `mkServiceSecretspecToml`, `collectServiceSecrets`, `setup-env`, `reconcile-secrets`, and `lib/docker-compose.nix`. These collect secret names/values, not provider metadata, so they should be unaffected.

## Goals / Non-Goals

**Goals:**
- Eliminate per-secret `providers` boilerplate in secret profiles and inline secrets
- Expose a three-tier override: global > service > environment
- Ship a sensible global default (`["saas-controller"]`) so most projects need zero configuration
- Emit SecretSpec-native `[profiles.<env>.defaults]` in generated TOML

**Non-Goals:**
- Per-secret default providers within saas-controller (the existing per-secret `providers` field on profiles/inline secrets is sufficient for overrides)
- Fallback chain documentation or testing beyond single-provider defaults (the list type supports it, but we're not optimizing for that use case now)
- Changing secret collection logic in `setup-env`, `reconcile-secrets`, or `docker-compose.nix`

## Decisions

### 1. Three-tier null-coalescing resolution

Default providers resolve as: `env.defaultProviders ?? service.secretspec.defaultProviders ?? config.saas-controller.defaultProviders`.

Each level defaults to `null` except the global, which defaults to `["saas-controller"]`. This means:
- Most projects: zero config, get `["saas-controller"]`
- Projects with a different vault: set global once
- Services with special needs: set at service level
- Environments with different backends: set at environment level

**Alternatives considered:**
- Merge/append semantics (each level adds to the chain): Rejected — more complex, unclear ordering semantics, and the immediate goal is reducing repetition not building fallback chains.
- Per-secret defaults only (no hierarchy): Rejected — doesn't reduce boilerplate, just moves it.

### 2. Emit `[profiles.<env>.defaults]` in TOML

The resolved default providers list for each environment is emitted as a `[profiles.<env>.defaults]` section before the `[profiles.<env>]` section. This is native SecretSpec syntax.

```toml
[profiles.local.defaults]
providers = ["saas-controller"]

[profiles.local]
TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret" }
```

**Alternatives considered:**
- Inject `providers` on every secret at TOML generation time (keep current pattern but compute from defaults): Rejected — pointless complexity when SecretSpec supports the cleaner pattern natively.

### 3. Strip `providers` from built-in profiles

Built-in secret profiles (tailscale in devenv.nix defaults, zudoku/zuplo in providers/zuplo.nix) currently hard-code `providers = ["saas-controller"]` on every secret. These will be removed so secrets inherit from profile-level defaults.

Per-secret `providers` on profile definitions remains available for overrides (e.g., a secret that genuinely comes from a different vault).

### 4. Option types

```nix
# Global
saas-controller.defaultProviders = lib.mkOption {
  type = lib.types.listOf lib.types.str;
  default = [ "saas-controller" ];
};

# Service-level
services.<name>.secretspec.defaultProviders = lib.mkOption {
  type = lib.types.nullOr (lib.types.listOf lib.types.str);
  default = null;
};

# Environment-level
services.<name>.secretspec.environments.<env>.defaultProviders = lib.mkOption {
  type = lib.types.nullOr (lib.types.listOf lib.types.str);
  default = null;
};
```

The global uses a concrete list (always has a value). Service and environment use `nullOr` so `null` means "inherit from parent."

## Risks / Trade-offs

- [Generated TOML format change] The `[profiles.*.defaults]` section is new output. Any downstream tooling that parses the generated TOML must handle it. -> SecretSpec itself handles it natively; this is documented SecretSpec syntax. The risk is with any custom parsers consumers may have built.

- [Provider profile authors must be aware] Providers that define `secretProfiles` should no longer include `providers` unless the secret genuinely needs a different alias. -> This is a convention change. Document in TEMPLATE.nix comments.

## Open Questions

None — design decisions were resolved during exploration.
