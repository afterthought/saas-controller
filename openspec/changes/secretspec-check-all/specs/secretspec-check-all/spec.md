## ADDED Requirements

### Requirement: Per-service secretspec option
The service submodule SHALL support an optional `secretspec` attribute set with the following fields:
- `path` (string, nullable): Directory containing secretspec.toml. Defaults to `providerConfig.path` when null.
- `tags` (list of strings): Labels for filtering. Defaults to empty list.
- `profiles` (list of strings): Secretspec profiles to validate. Defaults to `["default"]`.
- `checkProvider` (string, nullable): Secretspec provider for checks. When null, secretspec resolves the provider from its own config.

When `secretspec` is null (default), the service SHALL NOT participate in `sc check-secrets`.

#### Scenario: Service with secretspec config participates in checks
- **WHEN** a service has `secretspec = { tags = [ "tailscale" ]; profiles = [ "default" ]; }`
- **THEN** `sc check-secrets` SHALL validate that service's secretspec.toml with `secretspec check --profile default`

#### Scenario: Service without secretspec config is skipped
- **WHEN** a service has `secretspec = null` (default)
- **THEN** `sc check-secrets` SHALL not attempt to validate that service

#### Scenario: Service with custom path
- **WHEN** a service has `secretspec = { path = "shared/secrets/my-service"; }`
- **THEN** `sc check-secrets` SHALL look for secretspec.toml in `shared/secrets/my-service/` instead of `providerConfig.path`

### Requirement: Unified sc check-secrets command
The system SHALL provide an `sc check-secrets` command that validates all secretspec projects in a single invocation.

The command SHALL:
1. Generate the controller secretspec.toml (existing `generateControllerSecretspecCmd`) if `secretspecContext` is configured
2. Check controller profiles (dev-saas-controller, prod-saas-controller) if `secretspecContext` is configured
3. Check each enabled service with `secretspec != null`, running `secretspec check` for each profile
4. Count and report errors
5. Exit 0 if all checks pass, exit 1 if any check fails
6. Print a summary showing pass/fail status for each project and profile

#### Scenario: All secrets present
- **WHEN** user runs `sc check-secrets` and all required secrets are available in all projects
- **THEN** the command SHALL print a success summary and exit 0

#### Scenario: Missing required secret
- **WHEN** user runs `sc check-secrets` and a service is missing `TS_CLIENT_SECRET`
- **THEN** the command SHALL report the failing service and profile, print the total error count, and exit 1

#### Scenario: Optional secret missing
- **WHEN** a secretspec.toml declares `SC_TAILNET` with `required = false` and the secret is not set
- **THEN** `secretspec check` SHALL NOT count this as a failure

### Requirement: Tag-based filtering
The `sc check-secrets` command SHALL support a `--tag <tag>` flag that filters which services are checked.

When `--tag` is provided, only services whose `secretspec.tags` list contains the specified tag SHALL be checked. Controller profiles SHALL still be checked regardless of tag filter.

#### Scenario: Filter by tag
- **WHEN** user runs `sc check-secrets --tag tailscale`
- **THEN** only services with `"tailscale"` in their `secretspec.tags` SHALL be checked
- **AND** controller profiles SHALL still be checked

#### Scenario: No matching services for tag
- **WHEN** user runs `sc check-secrets --tag nonexistent`
- **THEN** controller profiles SHALL still be checked
- **AND** a message SHALL indicate no services matched the tag filter

### Requirement: Service-specific filtering
The `sc check-secrets` command SHALL support a `--service <name>` flag that checks only the named service.

#### Scenario: Check specific service
- **WHEN** user runs `sc check-secrets --service test-gateway`
- **THEN** only the test-gateway service's secretspec SHALL be checked (no controller profiles)

### Requirement: sc CLI integration
The `sc` command SHALL include `check-secrets` as a subcommand. `sc help` SHALL list `check-secrets` with a description.

#### Scenario: sc check-secrets subcommand
- **WHEN** user runs `sc check-secrets`
- **THEN** the unified check-secrets script SHALL execute

#### Scenario: sc help shows check-secrets
- **WHEN** user runs `sc help`
- **THEN** the help text SHALL include `check-secrets` with a description like "Validate secretspec projects"

### Requirement: Test-gateway secretspec.toml
The test-gateway example SHALL include a `secretspec.toml` declaring tailscale infrastructure secrets:
- `TS_CLIENT_SECRET`: required (default), description about OAuth client secret
- `TS_CLIENT_ID`: `required = false`, description about OAuth client ID
- `SC_TAILNET`: `required = false`, description about tailnet MagicDNS suffix and auto-detection

#### Scenario: test-gateway secretspec check with all secrets
- **WHEN** `TS_CLIENT_SECRET` is set and user runs `sc check-secrets`
- **THEN** the test-gateway check SHALL pass

#### Scenario: test-gateway secretspec check without optional secrets
- **WHEN** `TS_CLIENT_SECRET` is set but `TS_CLIENT_ID` and `SC_TAILNET` are not set
- **THEN** the test-gateway check SHALL still pass because those secrets are `required = false`

### Requirement: Deprecation of old check scripts
The existing scripts `check-saas-controller-secrets`, `check-dev-saas-controller`, and `check-prod-saas-controller` SHALL print a deprecation notice before executing their existing logic. The notice SHALL direct users to `sc check-secrets`.

#### Scenario: Old script prints deprecation
- **WHEN** user runs `check-saas-controller-secrets`
- **THEN** the script SHALL print a deprecation notice like "Deprecated: use 'sc check-secrets' instead"
- **AND** the script SHALL continue to execute its existing validation logic

### Requirement: Custom checkProvider support
When a service's `secretspec.checkProvider` is set, `sc check-secrets` SHALL pass `--provider <checkProvider>` to `secretspec check`. When null, the `--provider` flag SHALL be omitted.

#### Scenario: Service with explicit provider
- **WHEN** a service has `secretspec = { checkProvider = "dotenv"; profiles = [ "default" ]; }`
- **THEN** `sc check-secrets` SHALL run `secretspec check --provider dotenv --profile default`

#### Scenario: Service with null provider
- **WHEN** a service has `secretspec = { checkProvider = null; }` (default)
- **THEN** `sc check-secrets` SHALL run `secretspec check --profile default` without `--provider`
