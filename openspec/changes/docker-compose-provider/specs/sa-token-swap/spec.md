## ADDED Requirements

### Requirement: SA token option on service secretspec

The service secretspec submodule SHALL have a `saToken` option of type `nullOr str` defaulting to `null`. When set, it specifies the SA token alias for keyring retrieval before running `secretspec run` for that service.

#### Scenario: Service with SA token configured
- **WHEN** a service declares `secretspec.saToken = "client-willdan"`
- **THEN** `sc up` SHALL retrieve `OP_SA_CLIENT_WILLDAN` from the keyring and export it as `OP_SERVICE_ACCOUNT_TOKEN` before running `secretspec run` for that service

#### Scenario: Service without SA token
- **WHEN** a service has `secretspec.saToken = null` (default)
- **THEN** `sc up` SHALL use the inherited `OP_SERVICE_ACCOUNT_TOKEN` from the parent process without any keyring retrieval

### Requirement: SA token naming convention

The system SHALL provide a `toSASecretName` function that converts a hyphenated alias to an uppercase environment variable name: `"client-willdan"` -> `"OP_SA_CLIENT_WILLDAN"`. The transform SHALL uppercase the name, replace hyphens with underscores, and prepend `OP_SA_`.

#### Scenario: Standard client token name
- **WHEN** `toSASecretName "client-willdan"` is evaluated
- **THEN** the result SHALL be `"OP_SA_CLIENT_WILLDAN"`

#### Scenario: Multi-segment name
- **WHEN** `toSASecretName "agent-readwrite"` is evaluated
- **THEN** the result SHALL be `"OP_SA_AGENT_READWRITE"`

### Requirement: SA token retrieval from keyring

When `saToken` is set, the service's `sc up` subshell SHALL retrieve the SA token by running `secretspec get --provider keyring --profile default <tokenName>` in the `saTokensDir` directory. If retrieval fails (empty result), it SHALL print an error with remediation instructions and exit.

#### Scenario: Successful SA token retrieval
- **WHEN** `sc up` runs a service with `saToken = "client-willdan"` and the keyring contains `OP_SA_CLIENT_WILLDAN`
- **THEN** `OP_SERVICE_ACCOUNT_TOKEN` SHALL be set to the retrieved token value before `secretspec run` executes

#### Scenario: SA token not in keyring
- **WHEN** `sc up` runs a service with `saToken = "client-willdan"` and `OP_SA_CLIENT_WILLDAN` is not in the keyring
- **THEN** the script SHALL print an error referencing `store-sa-tokens` and exit with non-zero status

### Requirement: saTokensDir controller-level option

The system SHALL have a `saTokensDir` option at the controller level with default value `"$HOME/.config/secretspec/sa-tokens"`. This is the directory containing the SA token secretspec.toml managed by `__mac-nix`.

#### Scenario: Default saTokensDir
- **WHEN** no `saTokensDir` override is specified
- **THEN** SA token retrieval SHALL use `$HOME/.config/secretspec/sa-tokens`

#### Scenario: Custom saTokensDir
- **WHEN** `saas-controller.saTokensDir = "/opt/secrets/sa-tokens"` is configured
- **THEN** SA token retrieval SHALL use `/opt/secrets/sa-tokens`

### Requirement: Per-service secret injection in sc up

The `sc up` command SHALL inject secrets per-service rather than using a single re-exec. Each service SHALL run in its own subshell with: (1) SA token swap if `saToken` is configured, (2) `secretspec run --profile <env>` scoped to that service's generated secretspec dir, (3) the provider's `up()` script as the child process. The `__SC_SECRETS_INJECTED` re-exec pattern SHALL be removed.

#### Scenario: Two services with different SA tokens
- **WHEN** `sc up` runs with service A (`saToken = "client-willdan"`) and service B (`saToken = "client-integral"`)
- **THEN** service A's subshell SHALL have `OP_SERVICE_ACCOUNT_TOKEN` set to the client-willdan SA token, and service B's subshell SHALL have it set to the client-integral SA token, running in parallel

#### Scenario: Mixed SA token and no-SA-token services
- **WHEN** `sc up` runs with service A (`saToken = "client-willdan"`) and service B (`saToken = null`)
- **THEN** service A SHALL swap its SA token from keyring; service B SHALL use the inherited `OP_SERVICE_ACCOUNT_TOKEN`
