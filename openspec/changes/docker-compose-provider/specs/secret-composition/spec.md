## ADDED Requirements

### Requirement: Three-layer secret composition

The generated `secretspec.toml` for each service SHALL merge secrets from three sources in order: (1) controller-level profiles referenced by `serviceProfiles`, (2) provider-contributed profiles auto-included from the service's provider, (3) per-instance `secrets` declared inline on the environment. First occurrence wins on duplicate secret names.

#### Scenario: Full three-layer merge
- **WHEN** a service uses `provider = "zuplo"` with `secretspec.environments.local = { serviceProfiles = ["tailscale"]; secrets = { STRIPE_API_KEY = { description = "..."; providers = ["client-willdan"]; }; }; }`
- **THEN** the generated `[profiles.local]` section SHALL contain: `TS_CLIENT_SECRET`, `TS_CLIENT_ID`, `SC_TAILNET` (from tailscale profile), `ZUPLO_API_KEY` (auto-included from zuplo provider), and `STRIPE_API_KEY` (from inline secrets)

#### Scenario: Provider profile auto-included without explicit listing
- **WHEN** a service uses `provider = "zuplo"` and `serviceProfiles = ["tailscale"]` (no "zuplo" listed)
- **THEN** the generated TOML SHALL still include `ZUPLO_API_KEY` because the zuplo provider's `secretProfiles.zuplo` is auto-included

#### Scenario: Explicit provider profile listing is harmless
- **WHEN** a service lists `serviceProfiles = ["tailscale", "zuplo"]` and provider = "zuplo"
- **THEN** `ZUPLO_API_KEY` SHALL appear exactly once (deduplicated)

### Requirement: Per-instance extra secrets option

The service secretspec environment submodule SHALL have a `secrets` option of type `attrsOf (submodule { description, required, providers })` matching the same schema as `secretProfiles` entries. These secrets are appended to the generated TOML for that environment.

#### Scenario: Consumer adds instance-specific secrets
- **WHEN** a service declares `secretspec.environments.local.secrets = { MY_SECRET = { description = "Custom"; providers = ["client-willdan"]; }; }`
- **THEN** the generated `[profiles.local]` section SHALL include `MY_SECRET` with the specified description and providers

#### Scenario: Inline secret overrides profile secret
- **WHEN** a profile defines `FOO = { description = "from profile"; }` and the instance declares `secrets = { FOO = { description = "overridden"; }; }`
- **THEN** the generated TOML SHALL use the profile version (first occurrence wins — profiles are processed before inline secrets)

### Requirement: Provider profile auto-inclusion via provider lookup

The `mkServiceSecretspecToml` function SHALL look up `providers.${service.provider}.secretProfiles` and prepend those profile names to the environment's `serviceProfiles` list before collecting secrets. This makes provider secret profiles transparent to consumers.

#### Scenario: Provider without secretProfiles
- **WHEN** a service uses `provider = "hello-world"` (which has no `secretProfiles` attr)
- **THEN** no additional profiles are auto-included; only explicitly listed `serviceProfiles` are used

#### Scenario: Provider with multiple profiles
- **WHEN** a provider exports `secretProfiles = { foo = { ... }; bar = { ... }; }`
- **THEN** both `foo` and `bar` profiles SHALL be auto-included for services using that provider
