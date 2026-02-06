## ADDED Requirements

### Requirement: Controller-level secret profiles
The system SHALL support a `saas-controller.secretProfiles` option: an attrset mapping profile names to secret definitions. Each secret definition SHALL support `description` (required string), `required` (optional bool, defaults to true), and `providers` (optional list of strings).

Providers MAY register default secret profiles (e.g., zuplo.nix registering `zuplo-backend`). Consumers MAY extend or override profiles using standard nix merging (`lib.mkMerge`, `lib.mkForce`).

#### Scenario: Define a tailscale secret profile
- **WHEN** a consumer sets `saas-controller.secretProfiles.tailscale = { TS_CLIENT_SECRET = { description = "OAuth client secret"; }; TS_CLIENT_ID = { description = "OAuth client ID"; required = false; }; }`
- **THEN** the profile `tailscale` SHALL be available for services to reference in their `secretspec.environments`

#### Scenario: Provider registers default profiles
- **WHEN** a provider module sets `saas-controller.secretProfiles.zuplo-backend = { ZUPLO_API_KEY = { description = "..."; }; }`
- **THEN** services using that provider MAY reference `"zuplo-backend"` without redeclaring secrets

#### Scenario: Consumer extends a provider-registered profile
- **WHEN** a consumer uses `lib.mkMerge` to add secrets to an existing profile
- **THEN** the merged profile SHALL contain secrets from both the provider default and the consumer addition

### Requirement: Per-service per-environment secret profile selection
The service submodule SHALL support an optional `secretspec` attribute set with the following fields:
- `environments` (attrset): Maps environment names to `{ serviceProfiles = [ ... ]; }` where `serviceProfiles` is a list of secret profile names from `saas-controller.secretProfiles`.
- `tags` (list of strings): Labels for filtering in `sc check-secrets`. Defaults to empty list.
- `checkProvider` (string, nullable): Secretspec provider for checks. When null, secretspec resolves the provider from its own config.

When `secretspec` is null (default), the service SHALL NOT participate in `sc check-secrets`.

#### Scenario: Service selects different profiles per environment
- **WHEN** a service has `secretspec.environments = { local = { serviceProfiles = [ "tailscale" ]; }; edge = { serviceProfiles = [ "zuplo-backend" ]; }; }`
- **THEN** the generated TOML SHALL have a `[profiles.local]` section with tailscale secrets and a `[profiles.edge]` section with zuplo-backend secrets

#### Scenario: Service without secretspec is skipped
- **WHEN** a service has `secretspec = null` (default)
- **THEN** no TOML SHALL be generated and the service SHALL not participate in checks

#### Scenario: Multiple profiles in one environment
- **WHEN** a service has `secretspec.environments.local.serviceProfiles = [ "tailscale" "zuplo-public" ]`
- **THEN** the `[profiles.local]` section SHALL contain the union of secrets from both profiles

### Requirement: Dynamic TOML generation
For each service with `secretspec.environments` configured, the system SHALL generate a secretspec.toml at `.saas-controller/secretspec/<serviceName>/secretspec.toml`.

The generated file SHALL contain:
- A `[project]` section with `name` set to the service name and `revision = "1.0"`
- One `[profiles.<envName>]` section per configured environment
- Each profile section containing the union of all secrets from that environment's `serviceProfiles`
- Secret attributes (`description`, `required`, `providers`) preserved from the profile definition

Generation SHALL occur when `sc check-secrets` is invoked.

#### Scenario: Generated TOML structure
- **WHEN** service `test-gateway` has `secretspec.environments = { local = { serviceProfiles = [ "tailscale" ]; }; }`
- **THEN** the file `.saas-controller/secretspec/test-gateway/secretspec.toml` SHALL contain a `[project]` section with `name = "test-gateway"` and a `[profiles.local]` section with `TS_CLIENT_SECRET`, `TS_CLIENT_ID`, and `SC_TAILNET`

#### Scenario: Duplicate secret across profiles
- **WHEN** two service profiles both define the same secret name (e.g., both `profile-a` and `profile-b` define `API_KEY`)
- **THEN** the system SHALL use the first occurrence (from the first profile in the `serviceProfiles` list)

### Requirement: Unified sc check-secrets command
The system SHALL provide an `sc check-secrets` command that validates all service secretspec projects.

The command SHALL:
1. Generate secretspec.toml for each service with `secretspec.environments` configured
2. For each service, run `secretspec check --profile <envName>` for each configured environment
3. Pass `--provider <checkProvider>` if the service's `checkProvider` is non-null
4. Count and report errors per service and environment
5. Exit 0 if all checks pass, exit 1 if any check fails
6. Print a summary showing pass/fail status for each service/environment combination

#### Scenario: All secrets present
- **WHEN** user runs `sc check-secrets` and all required secrets are available
- **THEN** the command SHALL print a success summary and exit 0

#### Scenario: Missing required secret
- **WHEN** a service's `local` environment requires `TS_CLIENT_SECRET` and it is not set
- **THEN** the command SHALL report the failing service and environment, print the total error count, and exit 1

#### Scenario: Optional secret missing
- **WHEN** a secret has `required = false` and is not set
- **THEN** `secretspec check` SHALL NOT count this as a failure

### Requirement: Tag-based filtering
The `sc check-secrets` command SHALL support a `--tag <tag>` flag. When provided, only services whose `secretspec.tags` list contains the specified tag SHALL be checked.

#### Scenario: Filter by tag
- **WHEN** user runs `sc check-secrets --tag tailscale`
- **THEN** only services with `"tailscale"` in their `secretspec.tags` SHALL be checked

#### Scenario: No matching services
- **WHEN** user runs `sc check-secrets --tag nonexistent`
- **THEN** a message SHALL indicate no services matched the tag filter and the command SHALL exit 0

### Requirement: Service-specific filtering
The `sc check-secrets` command SHALL support a `--service <name>` flag that checks only the named service.

#### Scenario: Check specific service
- **WHEN** user runs `sc check-secrets --service test-gateway`
- **THEN** only the test-gateway service SHALL be checked

### Requirement: sc CLI integration
The `sc` command SHALL include `check-secrets` as a subcommand. `sc help` SHALL list `check-secrets` with a description.

#### Scenario: sc check-secrets subcommand
- **WHEN** user runs `sc check-secrets`
- **THEN** the unified check-secrets script SHALL execute

#### Scenario: sc help shows check-secrets
- **WHEN** user runs `sc help`
- **THEN** the help text SHALL include `check-secrets` with a description

### Requirement: Remove control plane secret management from core
The following options SHALL be removed from `saas-controller`:
- `secretspecContext`
- `profileProviders`
- `defaultProfileProvider`
- `environmentProfiles`
- `defaultSaasControllerProfile`

The `generateControllerSecretspecCmd` helper and the `.saas-controller/secretspec.toml` generation SHALL be removed.

The `withControlPlaneSecrets` wrapper, `resolveSaasControllerProfile`, and `resolveSaasControllerProvider` in `lib/helpers.nix` SHALL be removed. Deploy and hook tasks SHALL run without secretspec wrapping.

The `check-saas-controller-secrets`, `check-dev-saas-controller`, and `check-prod-saas-controller` scripts SHALL be removed.

#### Scenario: Deploy task runs without credential wrapping
- **WHEN** `sc deploy test-gateway -e edge` is invoked
- **THEN** the deploy task SHALL execute without `secretspec run` wrapping
- **AND** the task SHALL expect credentials (e.g., ZUPLO_API_KEY) to already be present in the environment

#### Scenario: Removed options cause evaluation error if referenced
- **WHEN** a consumer's devenv.nix references `saas-controller.profileProviders`
- **THEN** nix evaluation SHALL fail with an "option does not exist" error

### Requirement: Custom checkProvider support
When a service's `secretspec.checkProvider` is set, `sc check-secrets` SHALL pass `--provider <checkProvider>` to `secretspec check`. When null, the `--provider` flag SHALL be omitted.

#### Scenario: Service with explicit provider
- **WHEN** a service has `secretspec = { checkProvider = "dotenv"; ... }`
- **THEN** `sc check-secrets` SHALL run `secretspec check --provider dotenv --profile <env>`

#### Scenario: Service with null provider
- **WHEN** a service has `secretspec = { checkProvider = null; }` (default)
- **THEN** `sc check-secrets` SHALL run `secretspec check --profile <env>` without `--provider`
