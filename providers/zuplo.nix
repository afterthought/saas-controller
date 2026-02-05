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

      # Generate Dockerfile (shared by both services)
      cat > "$COMPOSE_DIR/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      COPY package.json ./
      RUN npm install
      DOCKERFILE

      # Generate docker-compose.yml with api + docs services
      cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
      services:
        zuplo-api:
          build:
            context: .
            dockerfile: Dockerfile
          volumes:
            - ${sourceDir}:/app
            - /app/node_modules
          ports:
            - "3000:3000"
          environment:
            - ZUDOKU_PUBLIC_SERVER_URL=http://localhost:3000
          command: ["npx", "zuplo", "dev", "--port", "3000", "--start-docs", "false", "--start-editor", "false"]

        zuplo-docs:
          build:
            context: .
            dockerfile: Dockerfile
          volumes:
            - ${sourceDir}:/app
            - /app/node_modules
          ports:
            - "3001:3001"
          environment:
            - ZUDOKU_PUBLIC_SERVER_URL=http://localhost:3000
          command: ["npx", "zuplo", "docs", "--port", "3001"]
      COMPOSEFILE

      export DEVSERVER_URL="http://localhost:3000"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      # Cleanup on exit
      cleanup() {
        echo "Stopping ${serviceName}..."
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      # Start compose stack in foreground
      docker compose -f "$COMPOSE_DIR/docker-compose.yml" up --build
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
