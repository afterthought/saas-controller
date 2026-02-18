## ADDED Requirements

### Requirement: SA token retrieval uses configurable provider alias

All SA token retrieval commands SHALL use `secretspec get --provider sa-tokens --profile default <TOKEN_NAME>` instead of the hardcoded `--provider keyring`. The `sa-tokens` provider alias is resolved by secretspec's user-level configuration (`~/.config/secretspec/config.toml` or platform equivalent).

#### Scenario: Developer using keyring (default)
- **WHEN** a developer configures `secretspec config provider add sa-tokens "keyring://"`
- **AND** runs `sc up` for a service with `saToken` configured
- **THEN** the SA token SHALL be retrieved from macOS Keychain via the `sa-tokens` alias

#### Scenario: Developer using environment variables
- **WHEN** a developer configures `secretspec config provider add sa-tokens "env://"`
- **AND** exports the SA token as an environment variable (e.g., `export OP_SA_CLIENT_WILLDAN=<token>`)
- **AND** runs `sc up` for a service with `saToken = "client-willdan"`
- **THEN** the SA token SHALL be read from the environment via the `sa-tokens` alias

#### Scenario: Provider alias not configured
- **WHEN** the `sa-tokens` provider alias is not configured in secretspec
- **AND** a service with `saToken` is started
- **THEN** the command SHALL fail with an error message that includes how to configure the alias

### Requirement: Shared SA swap snippet in helpers

All SA token swap logic SHALL be defined in a single shared function in `lib/helpers.nix` rather than duplicated across callsites. Both devenv.nix and providers/docker-compose.nix SHALL use this shared function.

#### Scenario: Consistent behavior across all callsites
- **WHEN** an SA token is retrieved during `sc up`, `sc deploy`, `sc check-secrets`, or persistent service startup
- **THEN** the retrieval logic, error messages, and environment export SHALL be identical across all code paths

#### Scenario: Single point of change
- **WHEN** the SA token retrieval logic is modified (e.g., alias name, error message, export variable)
- **THEN** only the shared function in `lib/helpers.nix` SHALL need to be updated

### Requirement: Provider-agnostic error messages

Error messages for SA token retrieval failures SHALL NOT reference keyring or any specific provider. They SHALL guide the developer to check their provider configuration.

#### Scenario: Token retrieval failure
- **WHEN** `secretspec get --provider sa-tokens` fails or returns empty
- **THEN** the error message SHALL include:
  - The token name that failed (e.g., `OP_SA_CLIENT_WILLDAN`)
  - The service name it was being retrieved for
  - A command to check the current provider config: `secretspec config provider list`
  - An example setup command: `secretspec config provider add sa-tokens 'keyring://'`

#### Scenario: No reference to keyring in error output
- **WHEN** any SA token error occurs
- **THEN** the error message SHALL NOT contain the word "keyring" or reference `store-sa-tokens`

### Requirement: Documentation covers SA token provider setup

README.md and the agent skill (skills/saas-controller/SKILL.md) SHALL document how to configure the SA token provider alias, including the env provider workflow.

#### Scenario: New developer setup with keyring
- **WHEN** a new developer reads the SA token setup documentation
- **THEN** they SHALL find a one-line command to configure keyring as their provider:
  `secretspec config provider add sa-tokens "keyring://"`

#### Scenario: Developer opting for environment variables
- **WHEN** a developer reads the SA token setup documentation
- **THEN** they SHALL find:
  - The command to set env as their provider: `secretspec config provider add sa-tokens "env://"`
  - How to export the required environment variables before running `sc up`
  - The naming convention for SA token env vars (`OP_SA_<UPPERCASE_ALIAS>`)

#### Scenario: Agent skill includes provider setup guidance
- **WHEN** an agent in a consuming repo uses the saas-controller skill
- **THEN** the skill SHALL include enough context about SA token provider configuration to guide developers through setup
