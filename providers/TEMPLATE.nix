# Template for creating a custom SaaS Controller provider
#
# Copy this file and implement the required functions for your cloud platform.
# Then register it via: saas-controller.externalProviders.my-provider = ./my-provider.nix;

{ pkgs, lib, config }:

{
  # OPTIONAL: Local dev lifecycle via docker-compose
  # Called by: sc up <service>
  # Args:
  #   - serviceName: Name of the service
  #   - service: Full service configuration object
  # Returns: Bash script string that:
  #   1. Creates .saas-controller/compose/${serviceName}/ directory
  #   2. Generates Dockerfile and docker-compose.yml
  #   3. Sets DEVSERVER_URL and prints it for VibeKanban capture
  #   4. Registers trap for cleanup (docker compose down on EXIT/INT/TERM)
  #   5. Runs docker compose up --build in foreground
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";
    in
    ''
      set -euo pipefail

      COMPOSE_DIR="${composeDir}"
      mkdir -p "$COMPOSE_DIR"

      # Generate Dockerfile
      cat > "$COMPOSE_DIR/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      # TODO: Add your base image and setup steps
      DOCKERFILE

      # Generate docker-compose.yml
      # TODO: Define your services. For composite services, add multiple entries.
      cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
      services:
        ${serviceName}:
          build:
            context: .
            dockerfile: Dockerfile
          volumes:
            - ${sourceDir}:/app
          ports:
            - "3000:3000"
          environment:
            - PORT=3000
          command: ["node", "server.mjs"]
      COMPOSEFILE

      export DEVSERVER_URL="http://localhost:3000"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      cleanup() {
        echo "Stopping ${serviceName}..."
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      docker compose -f "$COMPOSE_DIR/docker-compose.yml" up --build
    '';

  # REQUIRED: One-time project/account creation
  # Called by: provision-projects
  # Args:
  #   - serviceName: Name of the service being provisioned
  #   - service: Full service configuration object
  # Returns: Bash script that creates project-level resources
  provisionProject = serviceName: service: ''
    echo "  Creating project for ${serviceName}"
    echo "  Provider config: ${lib.generators.toPretty {} service.providerConfig}"

    # TODO: Add your project provisioning logic here
    # Examples:
    # - Create cloud project/account
    # - Set up IAM roles
    # - Initialize infrastructure
    # - Verify API credentials

    echo "  ✓ Project provisioned"
  '';

  # REQUIRED: Deploy code/config to environment
  # Called by: sc deploy <service> -e <environment>
  # Args:
  #   - serviceName: Name of the service being deployed
  #   - service: Full service configuration object
  #   - environment: Target environment name (e.g., "production", "edge")
  #   - envConfig: Environment-specific configuration
  #   - profile: SaaS controller profile name (e.g., "dev-saas-controller")
  #   - provider: SaaS controller provider name (e.g., "onepassword")
  # Note: Control plane secrets (API keys, etc.) are provided by wrapper in helpers.nix
  # Returns: Bash script that deploys the service
  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Deploying ${serviceName} to ${environment}"
    echo "  Project path: ${service.providerConfig.path}"

    # Change to project directory
    cd ${config.git.root}/${service.providerConfig.path}

    # TODO: Add your deployment logic here
    # Examples:
    # - Build application
    # - Upload code/artifacts
    # - Update configuration
    # - Trigger deployment
    # - Wait for health checks

    # Example deployment command:
    # ${pkgs.curl}/bin/curl -X POST https://api.example.com/deploy \
    #   -H "Authorization: Bearer $API_KEY" \
    #   -d '{"service": "${serviceName}", "env": "${environment}"}'

    echo "  ✓ Deployment successful"

    # RECOMMENDED: Write outputs for dependent services
    # This allows other services to reference your deployment (URLs, keys, etc.)
    mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
    cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
    {
      "service": "${serviceName}",
      "environment": "${environment}",
      "provider": "my-provider",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "outputs": {
        "appUrl": "https://${serviceName}-${environment}.example.com",
        "apiKey": "generated-or-retrieved-key"
      },
      "metadata": {
        "deployedBy": "''${USER:-unknown}",
        "gitCommit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
        "gitBranch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
      }
    }
    EOF
  '';

  # OPTIONAL: Hook provider interface (for pre/post-deploy hooks)
  # Called by: sc deploy <service> when configured in deploy.preHooks or deploy.postHooks
  # Args:
  #   - serviceName: Name of the service
  #   - provisionConfig: Hook configuration from deploy.preHooks/postHooks
  #   - servicePath: Path to service directory (from providerConfig.path)
  #   - environment: Target environment name
  #   - serviceConfig: Full service configuration (for accessing dependencies)
  # Note: Post-hooks receive deployment outputs via $DEVENV_TASKS_OUTPUTS
  # Returns: Bash script that executes the hook
  provision = serviceName: provisionConfig: servicePath: environment: serviceConfig: ''
    echo "  Running hook for ${serviceName}/${environment}"

    # TODO: Add your hook logic here
    # Examples (pre-deploy):
    # - Validate configuration
    # - Check prerequisites
    # - Backup current state
    # - Export secrets
    #
    # Examples (post-deploy):
    # - Send notifications
    # - Update external systems
    # - Run smoke tests
    # - Sync to monitoring/catalog

    # Access deployment outputs from previous tasks (post-deploy only):
    # if [ -n "$DEVENV_TASKS_OUTPUTS" ]; then
    #   APP_URL=$(echo "$DEVENV_TASKS_OUTPUTS" | ${pkgs.jq}/bin/jq -r \
    #     '.["saas-deploy:${serviceName}"].outputs.appUrl // empty')
    # fi

    echo "  ✓ Hook completed"
  '';
}
