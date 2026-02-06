## Context

SaaS Controller manages two distinct secret concerns:

1. **Control plane credentials** (ZUPLO_API_KEY, FRONTEGG_*): Needed by CI to authenticate to cloud providers when running `sc deploy`. Currently baked into the module via `secretspecContext`, `profileProviders`, `environmentProfiles`, and `withControlPlaneSecrets` wrapper in helpers.nix. In practice (willdan-dev), these are already handled externally — GitHub Actions loads them from 1Password and the module's built-in wrapping is redundant.

2. **Service-level secrets** (TS_CLIENT_SECRET, app API keys, database URLs): Needed by services at runtime. No validation mechanism exists — developers discover missing secrets when `sc up` fails or containers crash.

The secretspec fork (afterthought/secretspec at commit 8744fa9) supports `required = false`, `--provider`/`--profile` flags, and per-secret `providers` lists.

## Goals / Non-Goals

**Goals:**
- Decouple CI/deployment credential management from saas-controller core
- Introduce service profiles: named secret sets defined at the controller level, composable per-environment per-service
- Dynamically generate secretspec.toml per service from its service profile selections
- Unified `sc check-secrets` command validating all services across all environment profiles
- Tag-based and service-name filtering for targeted checks

**Non-Goals:**
- Managing CI/deployment credentials (ZUPLO_API_KEY) — this is the caller's responsibility
- Replacing the secretspec-export provider or include/exclude pattern system for deploy hooks
- Auto-running checks on shell entry or as `sc up` pre-flight (can be added later)
- Changes to the secretspec binary itself

## Decisions

### Decouple control plane secrets from saas-controller core

The `secretspecContext`, `profileProviders`, `environmentProfiles`, `defaultProfileProvider`, `defaultSaasControllerProfile` options and `generateControllerSecretspecCmd` are removed. The `withControlPlaneSecrets` wrapper in helpers.nix and the `resolveSaasControllerProfile`/`resolveSaasControllerProvider` helpers are removed. Deploy tasks run without secretspec wrapping — the caller provides credentials in the environment.

**Rationale**: Willdan-dev already handles this externally via GitHub Actions + 1Password. The module's wrapping is redundant and couples the core to a specific credential management strategy. For AWS-based deployments, OIDC auth from GitHub replaces 1Password entirely — the module shouldn't encode assumptions about how credentials arrive.

**Alternative considered**: Keep the options but make them optional. Rejected because it maintains dead code paths and confusing dual responsibility.

**Migration**: Consumers remove references to deleted options from their devenv.nix. CI workflows that already wrap `sc deploy` with `secretspec run` (like willdan-dev) need no changes. Those relying on the built-in wrapping must add `secretspec run` to their CI.

### Service profiles as controller-level named secret sets

New `saas-controller.secretProfiles` option: an attrset mapping profile names to secret definitions.

```nix
saas-controller.secretProfiles = {
  tailscale = {
    TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret"; };
    TS_CLIENT_ID = { description = "Tailscale OAuth client ID"; required = false; };
    SC_TAILNET = { description = "Tailnet MagicDNS suffix"; required = false; };
  };
  zuplo-backend = {
    ZUPLO_API_KEY = { description = "Zuplo API key for deployments"; };
  };
  zuplo-public = {
    ZUDOKU_PUBLIC_SERVER_URL = { description = "Public server URL for Zudoku"; };
  };
};
```

Providers can register defaults (e.g., zuplo.nix could add `zuplo-backend` and `zuplo-public`). Consumers can extend or override with `lib.mkForce` or `lib.mkMerge`.

**Rationale**: Named profiles are reusable across services. A new Zuplo site just picks `[ "tailscale" "zuplo-backend" ]` — no need to redeclare individual secrets. Different deployment types (backend-only vs full-stack) select different profile combinations.

**Alternative considered**: Per-service inline secret declarations. Rejected because it leads to duplication across services using the same provider.

### Per-environment service profile selection

Services select which service profiles apply for each environment:

```nix
saas-controller.services.atlas3-dev-gateway = {
  secretspec.environments = {
    local = { serviceProfiles = [ "tailscale" "zuplo-public" ]; };
    edge = { serviceProfiles = [ "zuplo-backend" "zuplo-public" ]; };
    production = { serviceProfiles = [ "zuplo-backend" "zuplo-public" ]; };
  };
};
```

**Rationale**: Tailscale secrets are only needed for local dev (`sc up`). Production deployments need provider API keys but not tailscale. Per-environment selection avoids false-positive check failures (e.g., requiring TS_CLIENT_SECRET in production).

**Alternative considered**: Single list of service profiles for all environments. Rejected because it would require all secrets to be present in all environments.

### Dynamic TOML generation per service

For each service with `secretspec.environments` configured, generate a secretspec.toml at `.saas-controller/secretspec/<serviceName>/secretspec.toml` with one `[profiles.<envName>]` section per environment. Each section contains the union of secrets from that environment's service profiles.

```toml
# Generated: .saas-controller/secretspec/atlas3-dev-gateway/secretspec.toml
[project]
name = "atlas3-dev-gateway"
revision = "1.0"

[profiles.local]
TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret" }
TS_CLIENT_ID = { description = "Tailscale OAuth client ID", required = false }
SC_TAILNET = { description = "Tailnet MagicDNS suffix", required = false }
ZUDOKU_PUBLIC_SERVER_URL = { description = "Public server URL for Zudoku" }

[profiles.edge]
ZUPLO_API_KEY = { description = "Zuplo API key for deployments" }
ZUDOKU_PUBLIC_SERVER_URL = { description = "Public server URL for Zudoku" }

[profiles.production]
ZUPLO_API_KEY = { description = "Zuplo API key for deployments" }
ZUDOKU_PUBLIC_SERVER_URL = { description = "Public server URL for Zudoku" }
```

Generation happens at check time (`sc check-secrets`), not at shell entry.

**Rationale**: Dynamic generation avoids maintaining static TOML files that drift from the nix config. The `.saas-controller/secretspec/` directory is ephemeral (gitignored).

### Tags for filtering only

Tags on the service secretspec config filter which services `sc check-secrets` validates. They do not affect generation or composition.

**Rationale**: Filtering is the immediate need. Composition is handled by service profiles.

## Risks / Trade-offs

- **[Risk: Breaking change for consumers using removed options]** Consumers referencing `secretspecContext`, `profileProviders`, etc. will get nix evaluation errors. → **Mitigation**: Document migration path. Willdan-dev already handles credentials externally so the code change is removing unused config. Other consumers need a one-time update to their CI.

- **[Risk: Deploy tasks fail without credentials]** Removing `withControlPlaneSecrets` means deploy tasks no longer inject credentials. If a caller forgets to provide them, `npx zuplo deploy` fails with auth errors. → **Mitigation**: Clear error messages from the provider CLI (e.g., "ZUPLO_API_KEY not set"). Can add optional validation in deploy tasks that checks for required env vars and prints guidance.

- **[Trade-off: Service profiles are flat, not hierarchical]** No inheritance between service profiles (e.g., `zuplo-full` extending `zuplo-backend`). → **Rationale**: Keep it simple. A service just lists multiple profiles. Composition via list union is clear and predictable.

- **[Trade-off: No enterShell or sc up pre-flight]** Checks are on-demand only. → **Rationale**: Automatic validation on shell entry slows the common case. Can be added as a follow-up.
