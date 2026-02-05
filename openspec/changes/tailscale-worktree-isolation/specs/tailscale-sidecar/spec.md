## ADDED Requirements

### Requirement: Tailscale sidecar in compose stacks
Each provider's generated docker-compose.yml SHALL include a `tailscale` service using `tailscale/tailscale:latest`. The tailscale service SHALL be configured with: `TS_HOSTNAME` set to the derived hostname, `TS_AUTHKEY` set to `${TS_CLIENT_SECRET}?ephemeral=true`, `TS_EXTRA_ARGS=--advertise-tags=tag:sc-dev`, `TS_SERVE_CONFIG=/config/serve.json`, `TS_STATE_DIR=/var/lib/tailscale`, `TS_USERSPACE=false`. The container SHALL have `cap_add: [NET_ADMIN]` and `devices: [/dev/net/tun]`.

#### Scenario: Tailscale sidecar starts with correct configuration
- **WHEN** a provider's `up()` generates and starts a compose stack
- **THEN** the stack SHALL include a `tailscale` service with the specified environment variables, capabilities, and device mappings

#### Scenario: Ephemeral node with OAuth client
- **WHEN** the tailscale sidecar authenticates
- **THEN** it SHALL use `TS_AUTHKEY` with `?ephemeral=true` so the node auto-removes when the container stops

### Requirement: Application containers share tailscale network namespace
All application containers in a provider's compose stack SHALL use `network_mode: service:tailscale` to share the tailscale sidecar's network namespace. Application containers SHALL depend on the tailscale service with `condition: service_healthy`.

#### Scenario: Network namespace sharing
- **WHEN** application containers start
- **THEN** they SHALL share the tailscale sidecar's network namespace, binding to `127.0.0.1` within that namespace

#### Scenario: Dependency ordering
- **WHEN** the compose stack starts
- **THEN** application containers SHALL NOT start until the tailscale service healthcheck passes

### Requirement: Tailscale healthcheck
The tailscale service SHALL define a healthcheck running `tailscale status` with interval 2s, timeout 5s, and 10 retries.

#### Scenario: Healthcheck passes when node is online
- **WHEN** the tailscale node authenticates and joins the tailnet
- **THEN** `tailscale status` SHALL return success and the healthcheck SHALL pass

#### Scenario: Healthcheck blocks dependent services
- **WHEN** the tailscale node is still authenticating
- **THEN** application containers SHALL remain in "waiting" state until the healthcheck passes

### Requirement: Serve config for HTTPS routing
Each provider's `up()` SHALL generate a `serve-config.json` file in `.saas-controller/compose/${serviceName}/`. The serve config SHALL map external HTTPS ports to internal HTTP services. For zuplo: `:443` → `http://127.0.0.1:3000` (api) and `:8443` → `http://127.0.0.1:3001` (docs). The config file SHALL be bind-mounted into the tailscale container at `/config/serve.json`.

#### Scenario: Zuplo serve config routes correctly
- **WHEN** the tailscale sidecar starts with the generated serve config
- **THEN** HTTPS requests to `${FQDN}:443` SHALL proxy to `http://127.0.0.1:3000` and HTTPS requests to `${FQDN}:8443` SHALL proxy to `http://127.0.0.1:3001`

#### Scenario: Serve config file generated alongside compose files
- **WHEN** a provider's `up()` script executes
- **THEN** `serve-config.json` SHALL be written to `.saas-controller/compose/${serviceName}/` before `docker compose up` is called

### Requirement: OAuth client credentials injection
`TS_CLIENT_ID` and `TS_CLIENT_SECRET` SHALL be injected into the compose environment via SecretSpec from 1Password. The provider's `up()` SHALL wrap the compose invocation with SecretSpec or pass credentials via a `.env` file in the compose directory.

#### Scenario: Credentials available to tailscale sidecar
- **WHEN** the compose stack starts
- **THEN** the tailscale service SHALL have access to `TS_CLIENT_SECRET` for authentication

#### Scenario: Credentials not hardcoded
- **WHEN** compose files are inspected
- **THEN** `TS_CLIENT_SECRET` SHALL reference an environment variable, NOT contain a literal secret value

### Requirement: Deterministic cross-service URL for Zudoku
The zuplo provider SHALL set `ZUDOKU_PUBLIC_SERVER_URL` to `https://${FQDN}:443` on the `zuplo-docs` container at compose generation time.

#### Scenario: Docs portal knows API gateway URL
- **WHEN** the zuplo compose stack is generated
- **THEN** `zuplo-docs` SHALL have `ZUDOKU_PUBLIC_SERVER_URL=https://${FQDN}:443` set as an environment variable

#### Scenario: URL computed before containers start
- **WHEN** the compose files are generated
- **THEN** `ZUDOKU_PUBLIC_SERVER_URL` SHALL be a fully-qualified HTTPS URL, not a placeholder or runtime-discovered value

### Requirement: sc up lifecycle with tailscale
`sc up` SHALL: (1) read `VK_WORKSPACE_ID` from the environment, (2) assert that tailscale is running on the host via `tailscale status`, (3) read the tailnet MagicDNS suffix from `tailscale status --json`, (4) start compose stacks with `docker compose up -d --wait`, (5) print `DEVSERVER_URL` with HTTPS tailnet FQDNs after healthchecks pass, (6) stream logs with `docker compose logs -f`.

#### Scenario: sc up with VibeKanban workspace
- **WHEN** `sc up` is executed with `VK_WORKSPACE_ID` set
- **THEN** it SHALL derive the slug from the first 8 chars, compute FQDNs, start compose stacks, wait for tailscale healthcheck, and print HTTPS URLs

#### Scenario: sc up asserts tailscale running
- **WHEN** `sc up` is executed and `tailscale status` fails
- **THEN** `sc up` SHALL exit with an error message indicating tailscale must be running

#### Scenario: URL printing after healthcheck
- **WHEN** `docker compose up -d --wait` completes successfully
- **THEN** `sc up` SHALL print `DEVSERVER_URL: https://${FQDN}:443` (and `:8443` for docs) before starting log streaming

### Requirement: Cleanup on exit
When `sc up` receives EXIT, INT, or TERM signals, it SHALL run `docker compose down` for all running stacks. Ephemeral tailscale nodes SHALL auto-remove from the tailnet when the sidecar container stops.

#### Scenario: Graceful shutdown
- **WHEN** `sc up` is interrupted with Ctrl-C
- **THEN** `docker compose down` SHALL be called and the tailscale ephemeral node SHALL disappear from the tailnet

#### Scenario: No stale nodes after restart
- **WHEN** a worktree's `sc up` is stopped and restarted
- **THEN** the previous ephemeral node SHALL already be removed, and a new node with the same hostname SHALL register cleanly
