# secretspec-provider-defaults

Profile-level default provider resolution with three-tier override (global, service, environment).

## Requirements

### Requirement: Global default providers option

The saas-controller module SHALL expose a `defaultProviders` option at the controller level. This option MUST accept a list of strings (provider alias names). The default value MUST be `["saas-controller"]`.

#### Scenario: No configuration set

- **WHEN** a project does not set `saas-controller.defaultProviders`
- **THEN** the resolved default providers for all services and environments SHALL be `["saas-controller"]`

#### Scenario: Global override

- **WHEN** a project sets `saas-controller.defaultProviders = ["acme-vault"]`
- **THEN** the resolved default providers for all services and environments SHALL be `["acme-vault"]` (unless overridden at a more specific level)

### Requirement: Service-level default providers option

The saas-controller module SHALL expose a `defaultProviders` option at the service secretspec level (`services.<name>.secretspec.defaultProviders`). This option MUST accept `null` or a list of strings. The default MUST be `null` (inherit from global).

#### Scenario: Service inherits global

- **WHEN** a service does not set `secretspec.defaultProviders` (value is `null`)
- **THEN** the service SHALL use the global `saas-controller.defaultProviders` value

#### Scenario: Service overrides global

- **WHEN** a service sets `secretspec.defaultProviders = ["billing-vault"]`
- **THEN** that service's environments SHALL use `["billing-vault"]` as the default (unless overridden at environment level)

### Requirement: Environment-level default providers option

The saas-controller module SHALL expose a `defaultProviders` option at the environment level (`services.<name>.secretspec.environments.<env>.defaultProviders`). This option MUST accept `null` or a list of strings. The default MUST be `null` (inherit from service or global).

#### Scenario: Environment inherits from service

- **WHEN** an environment does not set `defaultProviders` (value is `null`)
- **THEN** the environment SHALL use the service-level value, or the global value if the service-level is also `null`

#### Scenario: Environment overrides service and global

- **WHEN** an environment sets `defaultProviders = ["env"]`
- **THEN** that specific environment SHALL use `["env"]` regardless of service or global settings

### Requirement: Resolution chain

The system SHALL resolve default providers using the following precedence (most specific wins): environment > service > global. Resolution MUST use null-coalescing: the first non-null value in the chain wins.

#### Scenario: Full override chain

- **WHEN** global is `["saas-controller"]`, service is `["billing-vault"]`, and environment is `["env"]`
- **THEN** the environment SHALL resolve to `["env"]`

#### Scenario: Partial override chain

- **WHEN** global is `["saas-controller"]`, service is `null`, and environment is `["env"]`
- **THEN** the environment SHALL resolve to `["env"]`

#### Scenario: No overrides

- **WHEN** global is `["saas-controller"]`, service is `null`, and environment is `null`
- **THEN** the environment SHALL resolve to `["saas-controller"]`

### Requirement: TOML generation emits profile defaults

The `mkServiceSecretspecToml` function SHALL emit a `[profiles.<env>.defaults]` section containing the resolved `providers` list for each environment. This section MUST appear before the `[profiles.<env>]` secrets section.

#### Scenario: Generated TOML structure

- **WHEN** the resolved default providers for the `local` environment is `["saas-controller"]`
- **THEN** the generated TOML SHALL contain:
  ```
  [profiles.local.defaults]
  providers = ["saas-controller"]

  [profiles.local]
  SECRET_NAME = { description = "..." }
  ```

#### Scenario: Per-secret override in generated TOML

- **WHEN** a secret specifies `providers = ["other-vault"]` and the profile default is `["saas-controller"]`
- **THEN** the generated TOML SHALL emit the per-secret providers and the profile defaults separately:
  ```
  [profiles.local.defaults]
  providers = ["saas-controller"]

  [profiles.local]
  NORMAL = { description = "..." }
  SPECIAL = { description = "...", providers = ["other-vault"] }
  ```

### Requirement: Built-in profiles use inherited defaults

Built-in secret profile definitions (tailscale profile in devenv.nix, zudoku/zuplo profiles in providers/zuplo.nix) SHALL NOT specify `providers` on individual secrets. These secrets SHALL inherit from profile-level defaults.

#### Scenario: Tailscale profile secrets

- **WHEN** the tailscale secret profile is evaluated
- **THEN** `TS_CLIENT_SECRET` and `TS_CLIENT_ID` SHALL have `providers = []` (empty, inheriting from defaults)

#### Scenario: Zudoku profile secrets

- **WHEN** the zudoku secret profile is evaluated
- **THEN** `ZUDOKU_PUBLIC_AUTH_CLIENT_ID` and `ZUDOKU_PUBLIC_AUTH_ISSUER` SHALL have `providers = []` (empty, inheriting from defaults)

### Requirement: Provider template documents convention

The `providers/TEMPLATE.nix` file SHALL document that secret profiles should omit `providers` on individual secrets unless overriding the project-level default.

#### Scenario: Template documentation

- **WHEN** a developer reads `providers/TEMPLATE.nix`
- **THEN** the template SHALL include guidance that secrets inherit default providers from the profile-level defaults and should only specify `providers` when they need a different alias
