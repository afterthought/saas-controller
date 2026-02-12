{ pkgs, lib, config }:

let
  compose = import ../lib/docker-compose.nix { inherit lib; };
in
{
  # Secret profiles contributed by this provider
  secretProfiles = {
    # Zuplo deploy credentials (currently empty — deploy uses npx zuplo CLI auth)
    zuplo = { };

    # Zudoku docs authentication (Frontegg OAuth)
    zudoku = {
      ZUDOKU_PUBLIC_AUTH_CLIENT_ID = {
        description = "Frontegg OAuth client ID for Zudoku docs authentication";
        required = false;
        providers = [ "saas-controller" ];
        default = "22426e52-307b-4bf0-92c7-6f978f78a966";
      };
      ZUDOKU_PUBLIC_AUTH_ISSUER = {
        description = "Frontegg issuer URL for Zudoku docs authentication";
        required = false;
        providers = [ "saas-controller" ];
        default = "https://app-5lp8mgkiydtb.us.frontegg.com";
      };
    };
  };

  # Local dev lifecycle: generate docker-compose.yml with api + docs services
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";

      # Volume strategy:
      #   1. bind-mount host source for live reload
      #   2. named volume preserves npm-installed modules from image build,
      #      preventing the bind-mount from overwriting with host's node_modules
      #
      # Network strategy:
      #   All app containers share the tailscale sidecar's network namespace.
      #   Tailscale serve routes external HTTPS to internal HTTP ports.
      composeContent = compose.mkComposeFile {
        appServices = lib.concatStringsSep "\n" [
          "  zuplo-api:"
          "    build:"
          "      context: ."
          "      dockerfile: Dockerfile"
          "    network_mode: service:tailscale"
          "    depends_on:"
          "      tailscale:"
          "        condition: service_healthy"
          "    volumes:"
          "      - ${sourceDir}:/app"
          "      - node_modules:/app/node_modules"
          "    environment:"
          "      - ZUPLO_PUBLIC_SERVER_URL=https://\${FQDN}:8443"
          "      - ZUDOKU_PUBLIC_AUTH_CLIENT_ID=\${ZUDOKU_PUBLIC_AUTH_CLIENT_ID:-22426e52-307b-4bf0-92c7-6f978f78a966}"
          "      - ZUDOKU_PUBLIC_AUTH_ISSUER=\${ZUDOKU_PUBLIC_AUTH_ISSUER:-https://app-5lp8mgkiydtb.us.frontegg.com}"
          "      - __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=\${FQDN}"
          "    command: [\"npx\", \"zuplo\", \"dev\", \"--port\", \"30000\", \"--start-docs\", \"false\", \"--start-editor\", \"false\"]"
          ""
          "  zuplo-docs:"
          "    build:"
          "      context: ."
          "      dockerfile: Dockerfile"
          "    network_mode: service:tailscale"
          "    depends_on:"
          "      tailscale:"
          "        condition: service_healthy"
          "    volumes:"
          "      - ${sourceDir}:/app"
          "      - node_modules:/app/node_modules"
          "    environment:"
          "      - ZUPLO_PUBLIC_SERVER_URL=https://\${FQDN}:8443"
          "      - ZUDOKU_PUBLIC_AUTH_CLIENT_ID=\${ZUDOKU_PUBLIC_AUTH_CLIENT_ID:-22426e52-307b-4bf0-92c7-6f978f78a966}"
          "      - ZUDOKU_PUBLIC_AUTH_ISSUER=\${ZUDOKU_PUBLIC_AUTH_ISSUER:-https://app-5lp8mgkiydtb.us.frontegg.com}"
          "      - __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=\${FQDN}"
          "    command: [\"npx\", \"zuplo\", \"docs\", \"--port\", \"30001\"]"
        ];
        extraVolumes = [ "node_modules" ];
      };

      serveContent = compose.mkServeConfig [
        { port = 443; upstream = "http://127.0.0.1:30001"; }
        { port = 8443; upstream = "http://127.0.0.1:30000"; }
      ];
    in
    ''
      set -euo pipefail

      mkdir -p "${composeDir}"

      # Compute tailscale hostname and FQDN (exported for docker-compose interpolation)
      export TS_HOSTNAME="sc-$SC_SLUG-${serviceName}"
      export FQDN="$TS_HOSTNAME.$SC_TAILNET"

      # Copy all package.json files (root + workspaces) and lockfile into compose context
      cp "${sourceDir}/package.json" "${composeDir}/package.json"
      cp "${sourceDir}/package-lock.json" "${composeDir}/package-lock.json" 2>/dev/null \
        || cp "${sourceDir}/npm-shrinkwrap.json" "${composeDir}/package-lock.json" 2>/dev/null \
        || true
      # Copy workspace package.json files (e.g. docs/) preserving directory structure
      (cd "${sourceDir}" && find . -mindepth 2 -name package.json -not -path '*/node_modules/*' -exec sh -c '
        mkdir -p "${composeDir}/$(dirname "$1")"
        cp "$1" "${composeDir}/$1"
      ' _ {} \;)

      # Generate .env in source dir (Zuplo/Zudoku reads from project root .env)
      {
        echo "ZUPLO_PUBLIC_SERVER_URL=https://$FQDN:8443"
        echo "ZUDOKU_PUBLIC_AUTH_CLIENT_ID=''${ZUDOKU_PUBLIC_AUTH_CLIENT_ID:-22426e52-307b-4bf0-92c7-6f978f78a966}"
        echo "ZUDOKU_PUBLIC_AUTH_ISSUER=''${ZUDOKU_PUBLIC_AUTH_ISSUER:-https://app-5lp8mgkiydtb.us.frontegg.com}"
      } > "${sourceDir}/.env"

      # Generate Dockerfile (shared by both services)
      cat > "${composeDir}/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      COPY . .
      RUN npm install
      DOCKERFILE

      # Generate serve-config.json and docker-compose.yml
      ${compose.writeFile "${composeDir}/serve-config.json" serveContent}
      ${compose.writeFile "${composeDir}/docker-compose.yml" composeContent}

      # Print URL
      export DEVSERVER_URL="https://$FQDN:443"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      ${compose.mkComposeLifecycle {
        inherit composeDir serviceName;
        urls = [
          { label = "Docs"; url = "https://$FQDN:443"; }
          { label = "API"; url = "https://$FQDN:8443"; }
        ];
      }}
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
  # Control plane secrets are provided by wrapper in helpers.nix
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
