## ADDED Requirements

### Requirement: Shared tailscale sidecar generation

The system SHALL provide a `mkTailscaleSidecar` function in `lib/docker-compose.nix` that generates the tailscale sidecar service YAML snippet. The sidecar SHALL use `tailscale/tailscale:latest`, advertise `tag:sc-dev`, use `TS_AUTHKEY` from `TS_CLIENT_SECRET`, and include healthcheck polling via `tailscale status`.

#### Scenario: Generating sidecar for a single-port service
- **WHEN** `mkTailscaleSidecar` is called with hostname `sc-abc12345-miniflux`
- **THEN** the output SHALL be a YAML service block with `TS_HOSTNAME`, `TS_AUTHKEY`, `TS_EXTRA_ARGS=--advertise-tags=tag:sc-dev`, `TS_SERVE_CONFIG`, `TS_STATE_DIR`, `TS_USERSPACE=false`, `NET_ADMIN` capability, `/dev/net/tun` device, and healthcheck

### Requirement: Shared serve-config generation

The system SHALL provide a `mkServeConfig` function that generates `serve-config.json` from a list of port-to-upstream mappings. It SHALL use `${TS_CERT_DOMAIN}` placeholder for hostname resolution by containerboot.

#### Scenario: Multi-port serve config
- **WHEN** `mkServeConfig` is called with `[{ port = 443; upstream = "http://127.0.0.1:8080"; } { port = 8443; upstream = "http://127.0.0.1:3000"; }]`
- **THEN** the output SHALL be a JSON object with `TCP` entries for both ports and `Web` entries mapping `${TS_CERT_DOMAIN}:<port>` to the corresponding upstream proxy

#### Scenario: Single-port serve config
- **WHEN** `mkServeConfig` is called with `[{ port = 443; upstream = "http://127.0.0.1:3000"; }]`
- **THEN** the output SHALL have a single TCP/Web entry for port 443

### Requirement: Shared compose lifecycle

The system SHALL provide a `mkComposeLifecycle` function that generates the bash script for compose up/down/logs with error handling. The lifecycle SHALL: start compose detached with `--build --wait`, dump container logs on failure, set up a cleanup trap for `docker compose down`, print HTTPS URLs, and stream logs in the foreground.

#### Scenario: Successful startup
- **WHEN** the lifecycle script runs and `docker compose up -d --build --wait` succeeds
- **THEN** it SHALL print HTTPS URLs for each tailscale serve entry and stream logs via `docker compose logs -f`

#### Scenario: Startup failure
- **WHEN** `docker compose up -d --build --wait` fails
- **THEN** it SHALL dump the last 50 lines of container logs before exiting with error

#### Scenario: Process termination
- **WHEN** the lifecycle script receives SIGTERM, SIGINT, or EXIT
- **THEN** it SHALL run `docker compose down` for cleanup

### Requirement: docker-compose provider with compose overlay

The system SHALL provide a `docker-compose` provider that accepts a pre-authored `docker-compose.yml` and layers the tailscale sidecar via Docker Compose multi-file merge (`-f original.yml -f overlay.yml`). The overlay SHALL add the tailscale service and set `network_mode: service:tailscale` on all app services.

#### Scenario: Pre-authored compose with tailscale injection
- **WHEN** a service uses `provider = "docker-compose"` with `providerConfig.path = "services/miniflux"` and `providerConfig.tailscale = [{ port = 443; upstream = "http://127.0.0.1:8080"; }]`
- **THEN** the provider SHALL read `services/miniflux/docker-compose.yml`, generate a tailscale overlay at `.saas-controller/compose/<serviceName>/tailscale-overlay.yml`, generate `serve-config.json`, and run `docker compose -f <original> -f <overlay> up -d --build --wait`

#### Scenario: Overlay network mode injection
- **WHEN** the original compose file has services `web` and `db`
- **THEN** the overlay SHALL set `network_mode: service:tailscale` and `depends_on: tailscale: condition: service_healthy` on both `web` and `db` services

### Requirement: Zuplo provider delegates compose lifecycle

The `zuplo` provider SHALL delegate its compose lifecycle (tailscale sidecar, serve-config, up/down/logs, error handling) to the shared library functions. It SHALL retain ownership of: Dockerfile generation, npm workspace package.json copying, zuplo-specific compose services (api + docs), Vite host allowlist, and `ZUDOKU_PUBLIC_SERVER_URL` configuration.

#### Scenario: Zuplo up produces identical compose stack
- **WHEN** `sc up` runs a zuplo-backed service
- **THEN** the generated compose stack SHALL be functionally identical to the current output (same services, same network mode, same tailscale config, same volumes)

### Requirement: Hello-world provider delegates compose lifecycle

The `hello-world` provider SHALL delegate its compose lifecycle to the shared library. It SHALL only provide the app service definition (Node.js container with bind-mounted source).

#### Scenario: Hello-world up with shared lifecycle
- **WHEN** `sc up` runs a hello-world-backed service
- **THEN** it SHALL use `mkTailscaleSidecar`, `mkServeConfig`, and `mkComposeLifecycle` from the shared library
