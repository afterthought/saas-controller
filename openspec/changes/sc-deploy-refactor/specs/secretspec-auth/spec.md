## ADDED Requirements

### Requirement: Generic secretspec auth configuration

The `secretspec.auth` option SHALL replace the `saToken` option with a provider-agnostic authentication configuration. The `auth.provider` field SHALL accept a secretspec provider alias string that identifies how to authenticate to the secret backend at runtime.

#### Scenario: Service configures auth provider
- **WHEN** a service declares `secretspec.auth.provider = "client-willdan"`
- **THEN** the docker-compose provider uses this alias to authenticate to the secret backend via secretspec, without assuming 1Password-specific conventions

#### Scenario: Service omits auth
- **WHEN** a service does not set `secretspec.auth`
- **THEN** the service runs without per-service secret backend authentication (inherits ambient credentials)

### Requirement: Remove 1Password-specific naming from module

The `toSASecretName` helper and the `OP_SA_*` environment variable convention SHALL be removed from the saas-controller module. The resolution of provider aliases to concrete authentication credentials SHALL be delegated to the secretspec CLI.

#### Scenario: Provider alias resolution
- **WHEN** `secretspec.auth.provider = "client-willdan"` is configured
- **THEN** saas-controller passes `"client-willdan"` to secretspec and does NOT construct `OP_SA_CLIENT_WILLDAN` or any provider-specific environment variable names

### Requirement: Docker-compose provider uses auth abstraction

The docker-compose provider SHALL use `service.secretspec.auth.provider` instead of `service.secretspec.saToken` when setting up runtime secret access for containers.

#### Scenario: Container startup with auth
- **WHEN** a docker-compose service has `secretspec.auth.provider` set
- **THEN** the provider invokes `secretspec run --provider <alias>` (or equivalent) to authenticate before starting the container

#### Scenario: Container startup without auth
- **WHEN** a docker-compose service has no `secretspec.auth` configured
- **THEN** the provider starts the container without secretspec authentication wrapping
