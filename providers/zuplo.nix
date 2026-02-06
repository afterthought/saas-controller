{ pkgs, lib, config }:

{
  # Local dev lifecycle: generate docker-compose.yml with api + docs services
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";
    in
    ''
      set -euo pipefail

      COMPOSE_DIR="${composeDir}"
      mkdir -p "$COMPOSE_DIR"

      # Compute tailscale hostname and FQDN
      TS_HOSTNAME="sc-''${SC_SLUG}-${serviceName}"
      FQDN="''${TS_HOSTNAME}.''${SC_TAILNET}"

      # Copy package.json and lockfile into compose context for Dockerfile COPY
      cp "${sourceDir}/package.json" "$COMPOSE_DIR/package.json"
      cp "${sourceDir}/package-lock.json" "$COMPOSE_DIR/package-lock.json" 2>/dev/null \
        || cp "${sourceDir}/npm-shrinkwrap.json" "$COMPOSE_DIR/package-lock.json" 2>/dev/null \
        || true

      # Generate Dockerfile (shared by both services)
      # Installs dependencies at build time so they live in the image layer.
      cat > "$COMPOSE_DIR/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      COPY package.json package-lock.json* ./
      RUN npm ci || npm install
      DOCKERFILE

      # Generate serve-config.json for tailscale HTTPS routing
      cat > "$COMPOSE_DIR/serve-config.json" <<SERVECONFIG
      {
        "TCP": {
          "443": { "HTTPS": true },
          "8443": { "HTTPS": true }
        },
        "Web": {
          "$TS_HOSTNAME:443": {
            "Handlers": { "/": { "Proxy": "http://127.0.0.1:3000" } }
          },
          "$TS_HOSTNAME:8443": {
            "Handlers": { "/": { "Proxy": "http://127.0.0.1:3001" } }
          }
        }
      }
      SERVECONFIG

      # Generate docker-compose.yml with tailscale sidecar + api + docs services
      #
      # Volume strategy:
      #   1. "${sourceDir}:/app" — bind-mounts host source for live reload
      #   2. "node_modules:/app/node_modules" — named volume preserves the
      #      npm-installed modules from the image build, preventing the bind-mount
      #      from overwriting them with the host's (possibly empty) node_modules
      #
      # Network strategy:
      #   All app containers share the tailscale sidecar's network namespace.
      #   Tailscale serve routes external HTTPS to internal HTTP ports.
      cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
      services:
        tailscale:
          image: tailscale/tailscale:latest
          hostname: $TS_HOSTNAME
          environment:
            - TS_HOSTNAME=$TS_HOSTNAME
            - TS_AUTHKEY=\''${TS_CLIENT_SECRET}?ephemeral=true
            - TS_SERVE_CONFIG=/config/serve.json
            - TS_STATE_DIR=/var/lib/tailscale
            - TS_USERSPACE=false
          volumes:
            - ./serve-config.json:/config/serve.json:ro
            - ts-state:/var/lib/tailscale
          cap_add:
            - NET_ADMIN
          devices:
            - /dev/net/tun:/dev/net/tun
          healthcheck:
            test: ["CMD", "tailscale", "status"]
            interval: 2s
            timeout: 5s
            retries: 10

        zuplo-api:
          build:
            context: .
            dockerfile: Dockerfile
          network_mode: service:tailscale
          depends_on:
            tailscale:
              condition: service_healthy
          volumes:
            - ${sourceDir}:/app
            - node_modules:/app/node_modules
          environment:
            - ZUDOKU_PUBLIC_SERVER_URL=https://$FQDN:443
          command: ["npx", "zuplo", "dev", "--port", "3000", "--start-docs", "false", "--start-editor", "false"]

        zuplo-docs:
          build:
            context: .
            dockerfile: Dockerfile
          network_mode: service:tailscale
          depends_on:
            tailscale:
              condition: service_healthy
          volumes:
            - ${sourceDir}:/app
            - node_modules:/app/node_modules
          environment:
            - ZUDOKU_PUBLIC_SERVER_URL=https://$FQDN:443
          command: ["npx", "zuplo", "docs", "--port", "3001"]

      volumes:
        node_modules:
        ts-state:
      COMPOSEFILE

      # Cleanup on exit
      cleanup() {
        echo "Stopping ${serviceName}..."
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      # Start compose stack detached, wait for healthchecks
      docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d --build --wait

      # Print HTTPS URLs
      export DEVSERVER_URL="https://''${FQDN}:443"
      echo "DEVSERVER_URL: $DEVSERVER_URL"
      echo "  API:  https://''${FQDN}:443"
      echo "  Docs: https://''${FQDN}:8443"

      # Stream logs in foreground
      docker compose -f "$COMPOSE_DIR/docker-compose.yml" logs -f
    '';

  # Provision top-level Zuplo project (one-time operation)
  provisionProject = serviceName: service: ''
    echo "  Creating/verifying Zuplo project: ${service.providerConfig.project}"
    echo "  Account: ${service.providerConfig.account}"
    echo "  Path: ${service.providerConfig.path}"

    # Create project if it doesn't exist (safe to call multiple times)
    npx zuplo project create \
      --name ${service.providerConfig.project} \
      --account ${service.providerConfig.account}

    echo "  ✓ Project provisioned"
  '';

  # Provision environment-specific infrastructure
  # Control plane secrets provided by wrapper in helpers.nix
  provisionEnvironment = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Setting up Zuplo environment for ${service.providerConfig.project}/${environment}"
    echo "  ✓ Environment provisioned"
  '';

  # Deploy code/config to environment
  # Control plane secrets (ZUPLO_API_KEY) are provided by wrapper in helpers.nix
  deploy = serviceName: service: environment: envConfig: profile: provider:
    let
      # Skip --environment flag for preview to allow Zuplo CLI to auto-detect branch
      skipEnvironmentFlag = (environment == "preview");
    in
    ''
          echo "  Deploying ${service.providerConfig.project} to ${environment}"

          # Change to project directory
          cd ${config.git.root}/${service.providerConfig.path}

          # Deploy to Zuplo (control plane credentials provided by wrapper)
          echo "  Deploying to Zuplo..."
          npx zuplo deploy \
            --project ${service.providerConfig.project} \
            --account ${service.providerConfig.account} \
            ${if !skipEnvironmentFlag then "--environment ${lib.escapeShellArg environment}" else ""} \
            --no-verify-remote

          echo "  ✓ Deployment successful"

          # Generate outputs (if needed for dependent services)
          GATEWAY_URL="https://${service.providerConfig.project}-${environment}.zuplo.app"
          DOCS_URL="https://${service.providerConfig.project}-${environment}.zuplo.app/docs"

          echo "  Gateway URL: ''${GATEWAY_URL}"
          echo "  Docs URL: ''${DOCS_URL}"

          # Write output file for dependent services
          mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
          cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
      {
        "service": "${serviceName}",
        "environment": "${environment}",
        "provider": "zuplo",
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "outputs": {
          "gatewayUrl": "''${GATEWAY_URL}",
          "devPortalUrl": "''${DOCS_URL}",
          "project": "${service.providerConfig.project}",
          "account": "${service.providerConfig.account}"
        },
        "metadata": {
          "deployedBy": "''${USER:-unknown}",
          "gitCommit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
          "gitBranch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        }
      }
      EOF
    '';
}
