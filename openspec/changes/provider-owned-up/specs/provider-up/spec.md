## ADDED Requirements

### Requirement: Provider up() interface
Each provider SHALL implement an `up` function with signature `up = serviceName: service: ''...''` that returns a bash script string. The script SHALL generate a `docker-compose.yml` and `Dockerfile` in `.saas-controller/compose/${serviceName}/`, run `docker compose up` in foreground mode, stream logs to stdout, and clean up via `docker compose down` on exit signals (EXIT, INT, TERM).

#### Scenario: Provider implements up()
- **WHEN** a provider .nix file is loaded
- **THEN** it SHALL expose an `up` attribute that is a function accepting `serviceName` and `service` arguments and returning a bash script string

#### Scenario: Compose files generated in correct location
- **WHEN** a provider's `up()` script executes
- **THEN** it SHALL create `docker-compose.yml` and `Dockerfile` under `.saas-controller/compose/${serviceName}/`

#### Scenario: Cleanup on exit
- **WHEN** the `up()` script receives EXIT, INT, or TERM signals
- **THEN** it SHALL run `docker compose down` in the compose directory to stop and remove containers

### Requirement: Zuplo provider up() with composite services
The zuplo provider SHALL implement `up()` generating a docker-compose.yml with two services: `zuplo-api` (running `npx zuplo dev --port 3000 --start-docs false --start-editor false`) and `zuplo-docs` (running `npx zuplo docs --port 3001`). Both services SHALL use a `FROM node:22` base image, copy `package.json`, run `npm install`, bind-mount the source directory at `/app`, and use an anonymous volume for `/app/node_modules`. The `ZUDOKU_PUBLIC_SERVER_URL` environment variable SHALL be set to `http://localhost:3000`.

#### Scenario: Zuplo up starts both services
- **WHEN** `sc up` is called for a zuplo-based service
- **THEN** both `zuplo-api` and `zuplo-docs` containers SHALL start and stream interleaved logs

#### Scenario: Zuplo compose network
- **WHEN** zuplo compose services are running
- **THEN** both services SHALL share the default compose network, allowing inter-service communication

#### Scenario: Source code bind-mounted for live reload
- **WHEN** the zuplo compose stack starts
- **THEN** the service source directory SHALL be bind-mounted at `/app` with an anonymous volume at `/app/node_modules` to preserve installed dependencies

### Requirement: Hello-world provider up()
The hello-world provider SHALL implement `up()` generating a docker-compose.yml with a single service running `node server.mjs`. The service SHALL use a `FROM node:22` base image and bind-mount the source directory at `/app`.

#### Scenario: Hello-world up starts single container
- **WHEN** `sc up` is called for a hello-world service
- **THEN** a single container SHALL start running the node server with logs streaming to stdout

### Requirement: sc up calls provider.up
The `sc up` command SHALL iterate all enabled services with a `local` environment, call each service's provider `up()` function, start each compose stack in the background, print `DEVSERVER_URL` for each service, and wait for all stacks. The trap handler SHALL call `docker compose down` for all running stacks on exit.

#### Scenario: sc up with single service
- **WHEN** `sc up hello-world` is executed
- **THEN** it SHALL call the hello-world provider's `up()` function, start the compose stack, and print the service URL

#### Scenario: sc up with all services
- **WHEN** `sc up` is executed without a service argument
- **THEN** it SHALL start compose stacks for all enabled services with `local` environment and wait for all

#### Scenario: sc up prints DEVSERVER_URL
- **WHEN** a compose stack starts successfully
- **THEN** `sc up` SHALL print `DEVSERVER_URL: http://localhost:${PORT}` for VibeKanban capture

#### Scenario: sc up cleanup on exit
- **WHEN** `sc up` receives an exit signal
- **THEN** it SHALL run `docker compose down` for every running compose stack

### Requirement: Remove runtime axis
The module SHALL NOT define `defaultRuntime`, `externalRuntimes`, or per-service `runtime` options. The `runtimes/` directory SHALL be deleted. The `resolveRuntime` function SHALL be removed from `lib/helpers.nix`.

#### Scenario: Runtime options removed from devenv.nix
- **WHEN** the module is loaded
- **THEN** `saas-controller.defaultRuntime`, `saas-controller.externalRuntimes`, and `saas-controller.services.<name>.runtime` options SHALL NOT exist

#### Scenario: Runtime files deleted
- **WHEN** the codebase is inspected
- **THEN** `runtimes/dev-manager-mcp.nix`, `runtimes/docker-compose.nix`, `runtimes/launchd.nix`, and `runtimes/TEMPLATE.nix` SHALL NOT exist

### Requirement: Remove network axis
The module SHALL NOT define `defaultNetwork`, `externalNetworks`, or per-service `network` options. `lib/networks.nix` SHALL be deleted. The `resolveNetwork` function SHALL be removed from `lib/helpers.nix`.

#### Scenario: Network options removed from devenv.nix
- **WHEN** the module is loaded
- **THEN** `saas-controller.defaultNetwork`, `saas-controller.externalNetworks`, and `saas-controller.services.<name>.network` options SHALL NOT exist

#### Scenario: Network files deleted
- **WHEN** the codebase is inspected
- **THEN** `lib/networks.nix` SHALL NOT exist

### Requirement: Remove localVariants from provider interface
Providers SHALL NOT define `localVariants`. The `mkDevServeScript` function SHALL be removed from `lib/helpers.nix`. The dev-serve script generation block SHALL be removed from `devenv.nix`.

#### Scenario: localVariants removed from providers
- **WHEN** provider .nix files are inspected
- **THEN** neither zuplo.nix nor hello-world.nix SHALL contain a `localVariants` attribute

#### Scenario: mkDevServeScript removed
- **WHEN** `lib/helpers.nix` is inspected
- **THEN** the `mkDevServeScript` function SHALL NOT exist

### Requirement: Deploy pipeline unchanged
The deploy task builders (`mkPreDeployTask`, `mkDeployTask`, `mkPostDeployTask`), hook execution, secret management, and dependency validation SHALL remain unchanged.

#### Scenario: Deploy tasks still work
- **WHEN** `sc deploy <service> -e <environment>` is executed
- **THEN** the pre-deploy, deploy, and post-deploy task chain SHALL execute identically to before this change

### Requirement: Updated provider documentation
`providers/TEMPLATE.nix` SHALL document the `up()` function interface alongside `provisionProject` and `deploy`. `EXTENDING.md` SHALL be updated to describe the `up()` pattern, remove runtime/network extension sections, and provide examples of writing provider `up()` functions with docker-compose.

#### Scenario: TEMPLATE.nix documents up()
- **WHEN** a developer reads `providers/TEMPLATE.nix`
- **THEN** they SHALL find documentation and a skeleton implementation for the `up` function

#### Scenario: EXTENDING.md reflects new architecture
- **WHEN** a developer reads `EXTENDING.md`
- **THEN** it SHALL describe the provider `up()` pattern, SHALL NOT reference runtimes or networks as extension points, and SHALL include a docker-compose example
