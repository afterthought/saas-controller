## Tracking

Dex epic: `51kuid7q`

| Dex ID | Task Group |
|--------|-----------|
| ndq2kwfr | 1. Remove runtime/network infrastructure (1.1-1.7) |
| ku22xv4a | 2+3. Add provider up() + rewrite sc up (2.1-2.4, 3.1) |
| 869vsd1b | 4. Update documentation (4.1-4.2) |
| ea8xakn5 | 5. Verify (5.1-5.2) |

## 1. Remove runtime/network infrastructure

- [ ] 1.1 Delete `runtimes/dev-manager-mcp.nix`, `runtimes/docker-compose.nix`, `runtimes/launchd.nix`, `runtimes/TEMPLATE.nix` (entire `runtimes/` directory)
- [ ] 1.2 Delete `lib/networks.nix`
- [ ] 1.3 Remove `mkDevServeScript`, `resolveRuntime`, `resolveNetwork` from `lib/helpers.nix`
- [ ] 1.4 Remove runtime/network options from `devenv.nix`: `defaultRuntime`, `defaultNetwork`, `externalRuntimes`, `externalNetworks`, per-service `runtime` and `network` options
- [ ] 1.5 Remove runtime/network imports and bindings from `devenv.nix` (`builtinRuntimes`, `externalRuntimes`, `builtinNetworks`, `externalNetworks`, `runtimes`, `networks`)
- [ ] 1.6 Remove runtime/network-related assertions from `devenv.nix`
- [ ] 1.7 Remove dev-serve script generation block from `devenv.nix` config section (the `lib.flatten` block mapping over `enabledServices` calling `helpers.mkDevServeScript`)

## 2. Add provider up() interface

- [ ] 2.1 Implement `up = serviceName: service: ''...''` in `providers/hello-world.nix` — generate docker-compose.yml with single node:22 service, bind-mount source at /app, run `node server.mjs`, trap cleanup
- [ ] 2.2 Implement `up = serviceName: service: ''...''` in `providers/zuplo.nix` — generate docker-compose.yml with `zuplo-api` and `zuplo-docs` services, FROM node:22, bind-mount source, anonymous volume for node_modules, set ZUDOKU_PUBLIC_SERVER_URL, trap cleanup
- [ ] 2.3 Remove `localVariants` from `providers/zuplo.nix`
- [ ] 2.4 Remove `localVariants` from `providers/hello-world.nix`

## 3. Rewrite sc up command

- [ ] 3.1 Rewrite `sc up` in `devenv.nix` to iterate enabled services with `local` environment, call provider `up()` for each, start compose stacks in background, print DEVSERVER_URL per service, wait for all, and trap cleanup for all stacks

## 4. Update documentation

- [ ] 4.1 Update `providers/TEMPLATE.nix` to document the `up()` function interface with skeleton implementation
- [ ] 4.2 Update `EXTENDING.md` — remove runtime/network extension sections, add provider `up()` documentation with docker-compose examples

## 5. Verify

- [ ] 5.1 Verify the module evaluates without errors (no broken Nix references to removed runtimes/networks)
- [ ] 5.2 Verify `sc up hello-world` starts the compose stack and streams logs
