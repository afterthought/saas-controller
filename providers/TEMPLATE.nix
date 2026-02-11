# Template for creating a custom SaaS Controller provider
#
# Copy this file and implement the required functions for your cloud platform.
# Then register it via: saas-controller.externalProviders.my-provider = ./my-provider.nix;

{ pkgs, lib, config }:

{
  # OPTIONAL: Secret profiles contributed by this provider
  # Profiles declared here are automatically merged into saas-controller.secretProfiles.
  # When a service uses this provider, the provider's profiles are AUTO-INCLUDED
  # in the service's secretspec — no need to add them to serviceProfiles manually.
  # secretProfiles = {
  #   my-provider = {
  #     MY_API_KEY = { description = "API key for my-provider"; providers = [ "saas-controller" ]; };
  #     MY_SECRET = { description = "Shared secret"; required = false; providers = [ "saas-controller" ]; };
  #   };
  # };
  #
  # For services needing secrets from a client-scoped 1Password vault (not the
  # default SA token), set secretspec.saToken on the service:
  #   secretspec.saToken = "client-willdan";  # retrieves OP_SA_CLIENT_WILLDAN from keyring
  # sc up will swap the SA token before injecting secrets for that service.

  # OPTIONAL: Local dev lifecycle via docker-compose
  # Called by: sc up <service>
  # Args:
  #   - serviceName: Name of the service
  #   - service: Full service configuration object
  # Returns: Bash script string that generates compose files in
  #   .saas-controller/compose/${serviceName}/, starts the stack,
  #   prints DEVSERVER_URL, and cleans up on exit.
  # See providers/hello-world.nix for a minimal example,
  #     providers/zuplo.nix for a multi-service composite example.
  # up = serviceName: service: ''...'';

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
  #   - profile: SaaS controller profile name (legacy, unused)
  #   - provider: SaaS controller provider alias (legacy, unused)
  # Note: Control plane secrets must be in the environment (caller's responsibility)
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
