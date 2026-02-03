{ pkgs, lib, config }:

{
  # Provision provider interface for Frontegg app registration
  # Runs as part of service provisioning to register/update Frontegg apps

  # provisionConfig: The config block from provision.providers array entry
  # servicePath: Inherited from main providerConfig.path
  # environment: Runtime environment name (e.g., "local", "edge", "production")
  # serviceConfig: Full service configuration for accessing dependencies
  provision = serviceName: provisionConfig: servicePath: environment: serviceConfig: ''
        echo "  🔐 [frontegg] Registering app for ${serviceName}/${environment}"

        # Get environment-specific app name from provisionConfig or generate it
        ${if provisionConfig.appName or null != null then
          ''APP_NAME="${provisionConfig.appName}"''
        else
          ''APP_NAME="${serviceName}-${environment}"''
        }

        # Apply environment-specific override if exists
        ${lib.optionalString (provisionConfig.environments or { } != { }) ''
          ${lib.concatStringsSep "\n    " (lib.mapAttrsToList (envName: envOverride: ''
            if [ "${environment}" = "${envName}" ]; then
              ${lib.optionalString (envOverride.appName or null != null) ''
                APP_NAME="${envOverride.appName}"
              ''}
            fi
          '') (provisionConfig.environments or { }))}
        ''}

        # Get app URL from task outputs (from deploy task via DEVENV_TASKS_OUTPUTS)
        ${if serviceConfig.dependencies != [] then
          let
            gatewayDep = builtins.head serviceConfig.dependencies;
          in ''
            # Read deploy task outputs to get app URL
            # DEVENV_TASKS_OUTPUTS contains outputs from all previous tasks
            if [ -n "$DEVENV_TASKS_OUTPUTS" ] && [ "$DEVENV_TASKS_OUTPUTS" != "null" ]; then
              APP_URL=$(echo "$DEVENV_TASKS_OUTPUTS" | ${pkgs.jq}/bin/jq -r '.["saas-deploy:${gatewayDep}"].outputs.gatewayUrl // .["saas-deploy:${gatewayDep}"].outputs.appUrl // .["saas-deploy:${gatewayDep}"].outputs.docsUrl // empty')
              if [ -n "$APP_URL" ] && [ "$APP_URL" != "null" ]; then
                echo "  Using app URL from deploy task outputs: $APP_URL"
              else
                echo "  ⚠️  No valid URL found in task outputs, using placeholder"
                APP_URL="https://placeholder.example.com"
              fi
            else
              echo "  ⚠️  No task outputs available, using placeholder app URL"
              APP_URL="https://placeholder.example.com"
            fi
          ''
        else ''
          # No dependencies, use config or placeholder
          APP_URL="${if provisionConfig.appUrl or null != null then provisionConfig.appUrl else "https://placeholder.example.com"}"
        ''}

        # Register or update Frontegg app using frontegg-register.mjs
        echo "  Registering app: $APP_NAME"
        echo "  App URL: $APP_URL"

        cd ${config.git.root}
        ${pkgs.nodejs}/bin/node ${toString ./..}/scripts/frontegg-register.mjs \
          --app-name "$APP_NAME" \
          --app-url "$APP_URL"

        echo "  ✓ Frontegg app provisioned"

        # Write output file
        mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
        cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}-frontegg.json <<EOF
    {
      "serviceName": "${serviceName}",
      "environment": "${environment}",
      "provisionProvider": "frontegg",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "outputs": {
        "appName": "$APP_NAME",
        "appUrl": "$APP_URL"
      }
    }
    EOF
  '';

  # Legacy interfaces for backward compatibility during migration
  # These will be removed once migration is complete
  provisionProject = serviceName: service: ''
    echo "  Frontegg: No project-level provisioning needed (legacy interface)"
  '';

  provisionEnvironment = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Frontegg: Use provision provider interface (legacy interface called)"
  '';

  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Frontegg: App configuration updated during provisioning"
    echo "  No additional deployment steps required"
  '';
}
