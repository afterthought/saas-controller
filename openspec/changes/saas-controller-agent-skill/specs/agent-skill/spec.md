## ADDED Requirements

### Requirement: Skill directory structure

The skill SHALL be located at `skills/saas-controller/` in the repo root. It SHALL contain a `SKILL.md` file and a `references/` directory.

#### Scenario: Skill directory exists with required files
- **WHEN** examining `skills/saas-controller/`
- **THEN** the directory SHALL contain `SKILL.md`, `references/provider-reference.md`, `references/tailscale-setup.md`, and `references/secretspec-deep-dive.md`

### Requirement: SKILL.md frontmatter

The SKILL.md SHALL include YAML frontmatter with `name`, `description`, and `metadata` fields conforming to the skills.sh specification.

#### Scenario: Valid frontmatter
- **WHEN** parsing the SKILL.md YAML frontmatter
- **THEN** `name` SHALL be `saas-controller`, `description` SHALL mention configuring cloud services, sc up, sc deploy, and secretspec profiles, and `metadata` SHALL include `author` and `version` fields

### Requirement: Architecture section reflects provider-owned lifecycle

The SKILL.md SHALL include an architecture section showing provider-owned lifecycle. It SHALL NOT reference runtimes or networks as separate axes.

#### Scenario: No stale runtime/network references
- **WHEN** searching SKILL.md for "defaultRuntime", "defaultNetwork", "runtime =", "network ="
- **THEN** zero matches SHALL be found

#### Scenario: Provider-owned lifecycle described
- **WHEN** reading the architecture section
- **THEN** it SHALL explain that providers own the `up()` lifecycle, generate docker-compose stacks, and include tailscale sidecar for HTTPS

### Requirement: Minimal service example (Example A)

The SKILL.md SHALL include a complete, copy-paste-ready devenv.nix example for a minimal hello-world service.

#### Scenario: Minimal example is complete and correct
- **WHEN** an agent copies Example A into a devenv.nix
- **THEN** it SHALL be a valid nix expression that configures a service with `enable`, `provider`, `providerConfig`, and `environments.local.enable`

### Requirement: Zuplo with secretspec example (Example B)

The SKILL.md SHALL include a complete devenv.nix example for a zuplo service with secretspec configuration, multiple environments, and secret profiles.

#### Scenario: Zuplo example includes secretspec
- **WHEN** reading Example B
- **THEN** it SHALL include `secretspec.environments` with `serviceProfiles`, `secretspec.saToken`, and `secretspec.tags`

#### Scenario: Zuplo example includes multiple environments
- **WHEN** reading Example B
- **THEN** it SHALL show at least `local` and `edge` environments with different profile compositions

### Requirement: Secret profiles concept section

The SKILL.md SHALL include a dedicated section explaining the secret profiles concept: controller-level profile definitions, per-service composition, provider auto-export, and `sc check-secrets` filtering.

#### Scenario: Secret profiles section explains the two levels
- **WHEN** reading the secret profiles section
- **THEN** it SHALL show both a `saas-controller.secretProfiles` definition (controller level) and a `services.<name>.secretspec.environments` reference (service level)

#### Scenario: Provider auto-export explained
- **WHEN** reading the secret profiles section
- **THEN** it SHALL explain that providers with `secretProfiles` auto-merge into `saas-controller.secretProfiles` and services using that provider get the profiles automatically

### Requirement: CLI reference section

The SKILL.md SHALL include a CLI reference covering `sc up`, `sc deploy`, `sc check-secrets`, and `sc secret-status`.

#### Scenario: CLI reference includes all current commands
- **WHEN** reading the CLI reference
- **THEN** it SHALL document `sc up [service]`, `sc deploy [service] -e <env>`, `sc check-secrets [--tag TAG] [--service NAME]`, `sc secret-status`, and `sc help`

### Requirement: Provider reference in references/

The `references/provider-reference.md` file SHALL document each builtin provider with its required `providerConfig` keys, whether it supports `sc up`, and any auto-exported secret profiles.

#### Scenario: All builtin providers documented
- **WHEN** reading provider-reference.md
- **THEN** it SHALL include entries for `zuplo`, `frontegg`, `datadog`, `secretspec-export`, `docker-compose`, and `hello-world`

#### Scenario: Each provider entry is complete
- **WHEN** reading a provider entry
- **THEN** it SHALL list required providerConfig keys, state whether up() is supported, list auto-exported secretProfiles (if any), and provide a one-line description

### Requirement: Tailscale setup in references/

The `references/tailscale-setup.md` file SHALL document the one-time tailscale setup: ACL tag configuration, OAuth client creation, and credential storage.

#### Scenario: Tailscale setup is actionable
- **WHEN** an agent reads tailscale-setup.md
- **THEN** it SHALL be able to guide a user through the full setup including ACL tag JSON, OAuth client scope selection, and environment variable configuration

### Requirement: Secretspec deep dive in references/

The `references/secretspec-deep-dive.md` file SHALL document the full secretspec option tree including per-environment secrets, saToken configuration, tags, and check-secrets usage patterns.

#### Scenario: Advanced secretspec patterns documented
- **WHEN** reading secretspec-deep-dive.md
- **THEN** it SHALL show examples of per-instance extra secrets (`secretspec.environments.<env>.secrets`), tag-based filtering (`sc check-secrets --tag`), and saToken keyring retrieval

### Requirement: DeepWiki pointer

The SKILL.md SHALL include a section pointing agents to DeepWiki for deeper questions not covered by the skill.

#### Scenario: DeepWiki usage instruction
- **WHEN** reading the DeepWiki section
- **THEN** it SHALL provide the exact MCP call pattern: `ask_question("afterthought/saas-controller", "<question>")`

### Requirement: README.md reflects current architecture

The README.md SHALL be rewritten to remove all references to the runtime/network axis and document the provider-owned lifecycle accurately.

#### Scenario: No stale content
- **WHEN** searching README.md for "defaultRuntime", "defaultNetwork", "Runtimes", "Networks", "runtime =", "network ="
- **THEN** zero matches SHALL be found (except in historical context if needed)

#### Scenario: README includes full examples
- **WHEN** reading README.md
- **THEN** it SHALL include the same two examples from SKILL.md (minimal and zuplo+secretspec)

#### Scenario: README includes secret profiles
- **WHEN** reading README.md
- **THEN** it SHALL explain the secret profiles concept

### Requirement: CLAUDE.md is contributor-focused

CLAUDE.md SHALL focus exclusively on building saas-controller itself: nix patterns, project goals, architecture rationale, use cases, and contributor workflow (dex, openspec).

#### Scenario: No consumer-facing content in CLAUDE.md
- **WHEN** reading CLAUDE.md
- **THEN** it SHALL NOT contain CLI usage examples for `sc up` or `sc deploy`, full service configuration examples, or tailscale setup instructions (these belong in README/skill)

#### Scenario: Contributor content retained
- **WHEN** reading CLAUDE.md
- **THEN** it SHALL contain nix idioms, project goals, the extending guide reference, and dex/openspec workflow instructions
