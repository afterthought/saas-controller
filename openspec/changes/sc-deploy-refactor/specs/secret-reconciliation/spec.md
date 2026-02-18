## ADDED Requirements

### Requirement: Setup environment secrets

The `sc setup-env <environment>` command SHALL iterate all services with secretspec configuration for the given environment and report which secrets are set, missing, or using defaults. The command SHALL group output by provider alias to reduce context-switching.

#### Scenario: New environment with missing secrets
- **WHEN** user runs `sc setup-env production`
- **THEN** the command lists every secret for every service in the `production` environment, grouped by provider alias, showing status (set/missing/default) for each

#### Scenario: All secrets already configured
- **WHEN** user runs `sc setup-env local` and all secrets are present
- **THEN** the command reports all secrets as set and exits with code 0

#### Scenario: Invalid environment name
- **WHEN** user runs `sc setup-env staging`
- **THEN** the command exits with an error indicating `staging` is not a valid environment (must be local, production, or preview)

### Requirement: Diff secrets between environments

The `sc diff-secrets <env1> <env2>` command SHALL compare the secret status of all services between two environments. The output SHALL show, per secret: its status in env1, its status in env2, and whether they differ.

#### Scenario: Secrets differ between environments
- **WHEN** user runs `sc diff-secrets local production`
- **THEN** the output shows a table with columns: service, secret name, local status, production status, and highlights rows where status differs

#### Scenario: Environments have identical secret status
- **WHEN** user runs `sc diff-secrets production preview` and all secrets match
- **THEN** the output indicates no differences found

### Requirement: Reconcile secrets for an environment

The `sc reconcile-secrets [--environment <env>]` command SHALL show a comprehensive view of all secrets across all services for the specified environment (or all environments if omitted). Each secret SHALL display its status: set, missing (required), default (using default value), or optional-missing (not required, not set).

#### Scenario: Reconcile single environment
- **WHEN** user runs `sc reconcile-secrets --environment production`
- **THEN** the output shows all services and their secrets for the production environment with status indicators, highlighting any that need attention (missing required, or optional-missing that may need overrides)

#### Scenario: Reconcile all environments
- **WHEN** user runs `sc reconcile-secrets` without `--environment`
- **THEN** the output shows all services across all three environments, with status for each secret in each environment

#### Scenario: Exit code reflects missing required secrets
- **WHEN** required secrets are missing in the specified environment
- **THEN** the command exits with a non-zero exit code
