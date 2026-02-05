{ pkgs, lib, config, providers }:

let
  # Helper function to get enabled environments
  getEnabledEnvironments = service:
    lib.filterAttrs (_: env: env.enable) service.environments;

  # Resolve environment name to saas-controller profile
  # Returns the profile name to use for a given environment (e.g., "production" -> "prod-saas-controller")
  resolveSaasControllerProfile = envName:
    config.saas-controller.environmentProfiles.${envName} or config.saas-controller.defaultSaasControllerProfile;

  # Resolve saas-controller profile to secretspec provider
  # Returns the provider name to use for a given profile (e.g., "prod-saas-controller" -> "onepassword")
  resolveSaasControllerProvider = profileName:
    config.saas-controller.profileProviders.${profileName} or config.saas-controller.defaultProfileProvider;

  # Wrap a command with stack-specific secretspec context (control plane credentials)
  # This provides ZUPLO_API_KEY, FRONTEGG_CLIENT_ID, FRONTEGG_API_KEY, etc.
  # Args:
  #   stackPath: Path to the stack directory (e.g., "stacks/atlas3-dev-gateway")
  #   command: Raw bash command to wrap
  # Returns: Wrapped command that runs from stack directory with control plane secrets
  # Uses runtime variables $SAAS_PROVIDER and $SAAS_PROFILE set earlier in task
  withControlPlaneSecrets = stackPath: command: ''
    cd ${config.git.root}/${stackPath}
    ${pkgs.secretspec}/bin/secretspec run \
      --provider "$SAAS_PROVIDER" \
      --profile "$SAAS_PROFILE" -- bash -c ${lib.escapeShellArg "set -e; ${command}"} || {
        echo "  ❌ secretspec run failed (exit code: $?)"
        exit 1
      }
  '';

  # Run hooks for a service (pre-deploy or post-deploy)
  # Orchestrates all hooks (secretspec, frontegg, datadog) in order
  # Args:
  #   serviceName: Name of the service
  #   service: Full service configuration
  #   hooks: List of hook configurations
  #   hookPhase: "pre" or "post" (for logging)
  #   environment: Runtime environment name
  # Returns: Bash script that runs all hooks with control plane secrets
  runHooks = serviceName: service: hooks: hookPhase: environment:
    let
      envConfig = service.environments.${environment} or { };
      skipSecretExport = envConfig.skipSecretExport or false;
    in
    if skipSecretExport then ''
      echo "🔧 [${serviceName}] Checking ${hookPhase}-deploy hooks for environment: ${environment}"
      echo "  ⏭️  Skipping ${hookPhase}-deploy hooks (skipSecretExport=true for ${environment})"

      echo ""
      echo "✅ All ${hookPhase}-deploy hooks completed for ${serviceName}/${environment}"
    '' else if hooks == [ ] then ''
      echo "🔧 [${serviceName}] Running ${hookPhase}-deploy hooks for environment: ${environment}"
      echo "  ⏭️  No ${hookPhase}-deploy hooks configured"

      echo ""
      echo "✅ All ${hookPhase}-deploy hooks completed for ${serviceName}/${environment}"
    '' else ''
      echo "🔧 [${serviceName}] Running ${hookPhase}-deploy hooks for environment: ${environment}"
      ${lib.concatStringsSep "\n    " (lib.imap0 (index: hookConfig:
        let
          hookType = hookConfig.type;
          hookProvider = providers.${hookType};
          servicePath = service.providerConfig.path;
        in ''
          echo ""
          echo "  [${toString (index + 1)}/${toString (builtins.length hooks)}] Running ${hookType} hook..."
          ${withControlPlaneSecrets "stacks/${serviceName}" (hookProvider.provision serviceName hookConfig.config servicePath environment service)}
        ''
      ) hooks)}

      echo ""
      echo "✅ All ${hookPhase}-deploy hooks completed for ${serviceName}/${environment}"
    '';

in
{
  # Create a task for secret export operation
  # Environment is passed as JSON input at runtime
  mkSecretExportTask = exportName: exportConfig:
    let
      provider = providers.${exportConfig.provider};
      taskName = "saas-secret-export:${exportName}";
    in
    {
      name = taskName;
      value = {
        description = "Export secrets for ${exportConfig.displayName} (environment via JSON input)";
        exec = ''
          set -e

          # Parse JSON input
          ENV=$(echo "$DEVENV_TASK_INPUT" | ${pkgs.jq}/bin/jq -r '.environment')

          if [ -z "$ENV" ] || [ "$ENV" = "null" ]; then
            echo "❌ Error: 'environment' field required in JSON input" >&2
            exit 1
          fi

          echo "🔐 Exporting secrets: ${exportName} → $ENV"

          # Resolve saas-controller profile and provider for this environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: _:
            let
              profile = resolveSaasControllerProfile envName;
              providerName = resolveSaasControllerProvider profile;
            in ''
              if [ "$ENV" = "${envName}" ]; then
                SAAS_PROFILE="${profile}"
                SAAS_PROVIDER="${providerName}"
              fi
            ''
          ) config.saas-controller.environmentProfiles)}

          # Fallback to defaults if environment not mapped
          SAAS_PROFILE="''${SAAS_PROFILE:-${config.saas-controller.defaultSaasControllerProfile}}"
          SAAS_PROVIDER="''${SAAS_PROVIDER:-${config.saas-controller.defaultProfileProvider}}"

          echo "  🔑 Using saas-controller profile: $SAAS_PROFILE (provider: $SAAS_PROVIDER)"

          # Select environment config and wrap with control plane secrets
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: envConfig:
            let
              profile = resolveSaasControllerProfile envName;
              providerName = resolveSaasControllerProvider profile;

              # Get raw command from provider
              rawCommand = provider.deploy exportName exportConfig envName envConfig profile providerName;

              # Wrap with control plane secrets
            in ''
              if [ "$ENV" = "${envName}" ]; then
                ${withControlPlaneSecrets "stacks/${exportName}" rawCommand}
              fi
            ''
          ) (getEnabledEnvironments exportConfig))}

          # Write outputs for devenv (dependent tasks)
          cat > "$DEVENV_TASK_OUTPUT_FILE" <<EOF
          {
            "service": "${exportName}",
            "environment": "$ENV",
            "status": "success",
            "action": "secret-export",
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "saas_profile": "$SAAS_PROFILE",
            "saas_provider": "$SAAS_PROVIDER"
          }
          EOF

          # Also write to data store (for audit/remote sync)
          mkdir -p "${config.git.root}/.saas-controller/outputs/${exportName}"
          cp "$DEVENV_TASK_OUTPUT_FILE" "${config.git.root}/.saas-controller/outputs/${exportName}/$ENV-export.json"

          echo "✅ Secret export completed: ${exportName} → $ENV"
        '';
      };
    };

  # Create a task for pre-deploy hooks
  # Environment is passed as JSON input at runtime
  # Runs all pre-deploy hooks (secretspec, etc.) in order
  mkPreDeployTask = serviceName: service:
    let
      taskName = "saas-pre-deploy:${serviceName}";
    in
    {
      name = taskName;
      value = {
        description = "Run pre-deploy hooks for ${service.displayName} (environment via JSON input)";
        exec = ''
          set -e

          # Parse JSON input
          ENV=$(echo "$DEVENV_TASK_INPUT" | ${pkgs.jq}/bin/jq -r '.environment')

          if [ -z "$ENV" ] || [ "$ENV" = "null" ]; then
            echo "❌ Error: 'environment' field required in JSON input" >&2
            exit 1
          fi

          echo "⚡ Pre-deploy hooks: ${serviceName} → $ENV"

          # Resolve saas-controller profile and provider for this environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: _:
            let
              profile = resolveSaasControllerProfile envName;
              providerName = resolveSaasControllerProvider profile;
            in ''
              if [ "$ENV" = "${envName}" ]; then
                SAAS_PROFILE="${profile}"
                SAAS_PROVIDER="${providerName}"
              fi
            ''
          ) config.saas-controller.environmentProfiles)}

          # Fallback to defaults if environment not mapped
          SAAS_PROFILE="''${SAAS_PROFILE:-${config.saas-controller.defaultSaasControllerProfile}}"
          SAAS_PROVIDER="''${SAAS_PROVIDER:-${config.saas-controller.defaultProfileProvider}}"

          echo "  🔑 Using saas-controller profile: $SAAS_PROFILE (provider: $SAAS_PROVIDER)"

          # Run pre-deploy hooks for the matching environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: envConfig: ''
            if [ "$ENV" = "${envName}" ]; then
              (
                ${runHooks serviceName service service.deploy.preHooks "pre" envName}
              ) || {
                echo ""
                echo "❌ Pre-deploy hooks failed for ${serviceName} in environment $ENV"
                exit 1
              }
            fi
          '') (getEnabledEnvironments service))}

          # Write outputs for devenv (dependent tasks)
          cat > "$DEVENV_TASK_OUTPUT_FILE" <<EOF
          {
            "service": "${serviceName}",
            "environment": "$ENV",
            "status": "success",
            "action": "pre-deploy",
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "saas_profile": "$SAAS_PROFILE",
            "saas_provider": "$SAAS_PROVIDER"
          }
          EOF

          # Also write to data store (for audit/remote sync)
          mkdir -p "${config.git.root}/.saas-controller/outputs/${serviceName}"
          cp "$DEVENV_TASK_OUTPUT_FILE" "${config.git.root}/.saas-controller/outputs/${serviceName}/$ENV-pre-deploy.json"

          echo "✅ Pre-deploy hooks completed: ${serviceName} → $ENV"
        '';
      };
    };

  # Create a task for service deployment
  # Environment is passed as JSON input at runtime
  mkDeployTask = serviceName: service:
    let
      provider = providers.${service.provider};
      taskName = "saas-deploy:${serviceName}";
    in
    {
      name = taskName;
      value = {
        description = "Deploy ${service.displayName} (environment via JSON input)";
        exec = ''
          set -e

          # Parse JSON input
          ENV=$(echo "$DEVENV_TASK_INPUT" | ${pkgs.jq}/bin/jq -r '.environment')

          if [ -z "$ENV" ] || [ "$ENV" = "null" ]; then
            echo "❌ Error: 'environment' field required in JSON input" >&2
            exit 1
          fi

          echo "🚀 Deploying: ${serviceName} → $ENV"

          # Resolve saas-controller profile and provider for this environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: _:
            let
              profile = resolveSaasControllerProfile envName;
              providerName = resolveSaasControllerProvider profile;
            in ''
              if [ "$ENV" = "${envName}" ]; then
                SAAS_PROFILE="${profile}"
                SAAS_PROVIDER="${providerName}"
              fi
            ''
          ) config.saas-controller.environmentProfiles)}

          # Fallback to defaults if environment not mapped
          SAAS_PROFILE="''${SAAS_PROFILE:-${config.saas-controller.defaultSaasControllerProfile}}"
          SAAS_PROVIDER="''${SAAS_PROVIDER:-${config.saas-controller.defaultProfileProvider}}"

          echo "  🔑 Using saas-controller profile: $SAAS_PROFILE (provider: $SAAS_PROVIDER)"

          # Select environment config and wrap with control plane secrets
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: envConfig:
            let
              profile = resolveSaasControllerProfile envName;
              providerName = resolveSaasControllerProvider profile;

              # Get raw command from provider
              rawCommand = provider.deploy serviceName service envName envConfig profile providerName;

              # Wrap with control plane secrets (ZUPLO_API_KEY, FRONTEGG_*, etc.)
              # Runs secretspec from the stack directory (stacks/${serviceName})
            in ''
              if [ "$ENV" = "${envName}" ]; then
                (
                  ${withControlPlaneSecrets "stacks/${serviceName}" rawCommand}
                ) || {
                  echo ""
                  echo "❌ Deployment failed for ${serviceName} in environment $ENV"
                  exit 1
                }
              fi
            ''
          ) (getEnabledEnvironments service))}

          # Read provider outputs (written by provider)
          PROVIDER_OUTPUT_FILE="${config.git.root}/.saas-controller/outputs/${serviceName}/$ENV.json"

          if [ -f "$PROVIDER_OUTPUT_FILE" ]; then
            # Merge provider outputs with task metadata
            ${pkgs.jq}/bin/jq -n \
              --arg service "${serviceName}" \
              --arg env "$ENV" \
              --arg action "deploy" \
              --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              --arg saas_profile "$SAAS_PROFILE" \
              --arg saas_provider "$SAAS_PROVIDER" \
              --argjson provider_data "$(cat "$PROVIDER_OUTPUT_FILE")" \
              '{
                service: $service,
                environment: $env,
                status: "success",
                action: $action,
                timestamp: $timestamp,
                saas_profile: $saas_profile,
                saas_provider: $saas_provider,
                outputs: $provider_data.outputs
              }' > "$DEVENV_TASK_OUTPUT_FILE"
          else
            # No provider outputs, just task metadata
            cat > "$DEVENV_TASK_OUTPUT_FILE" <<EOF
          {
            "service": "${serviceName}",
            "environment": "$ENV",
            "status": "success",
            "action": "deploy",
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "saas_profile": "$SAAS_PROFILE",
            "saas_provider": "$SAAS_PROVIDER"
          }
          EOF
          fi

          echo "✅ Deployment completed: ${serviceName} → $ENV"
        '';
      };
    };

  # Create a task for post-deploy hooks
  # Environment is passed as JSON input at runtime
  # Runs all post-deploy hooks (frontegg, datadog, etc.) in order
  # Post-hooks receive deployment outputs via DEVENV_TASKS_OUTPUTS
  mkPostDeployTask = serviceName: service:
    let
      taskName = "saas-post-deploy:${serviceName}";
    in
    {
      name = taskName;
      value = {
        description = "Run post-deploy hooks for ${service.displayName} (environment via JSON input)";
        exec = ''
          set -e

          # Parse JSON input
          ENV=$(echo "$DEVENV_TASK_INPUT" | ${pkgs.jq}/bin/jq -r '.environment')

          if [ -z "$ENV" ] || [ "$ENV" = "null" ]; then
            echo "❌ Error: 'environment' field required in JSON input" >&2
            exit 1
          fi

          echo "⚡ Post-deploy hooks: ${serviceName} → $ENV"

          # Resolve saas-controller profile and provider for this environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: _:
            let
              profile = resolveSaasControllerProfile envName;
              providerName = resolveSaasControllerProvider profile;
            in ''
              if [ "$ENV" = "${envName}" ]; then
                SAAS_PROFILE="${profile}"
                SAAS_PROVIDER="${providerName}"
              fi
            ''
          ) config.saas-controller.environmentProfiles)}

          # Fallback to defaults if environment not mapped
          SAAS_PROFILE="''${SAAS_PROFILE:-${config.saas-controller.defaultSaasControllerProfile}}"
          SAAS_PROVIDER="''${SAAS_PROVIDER:-${config.saas-controller.defaultProfileProvider}}"

          echo "  🔑 Using saas-controller profile: $SAAS_PROFILE (provider: $SAAS_PROVIDER)"

          # Run post-deploy hooks for the matching environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: envConfig: ''
            if [ "$ENV" = "${envName}" ]; then
              (
                ${runHooks serviceName service service.deploy.postHooks "post" envName}
              ) || {
                echo ""
                echo "❌ Post-deploy hooks failed for ${serviceName} in environment $ENV"
                exit 1
              }
            fi
          '') (getEnabledEnvironments service))}

          # Write outputs for devenv (dependent tasks)
          cat > "$DEVENV_TASK_OUTPUT_FILE" <<EOF
          {
            "service": "${serviceName}",
            "environment": "$ENV",
            "status": "success",
            "action": "post-deploy",
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "saas_profile": "$SAAS_PROFILE",
            "saas_provider": "$SAAS_PROVIDER"
          }
          EOF

          # Also write to data store (for audit/remote sync)
          mkdir -p "${config.git.root}/.saas-controller/outputs/${serviceName}"
          cp "$DEVENV_TASK_OUTPUT_FILE" "${config.git.root}/.saas-controller/outputs/${serviceName}/$ENV-post-deploy.json"

          echo "✅ Post-deploy hooks completed: ${serviceName} → $ENV"
        '';
      };
    };

  # Build dependency list for a service deployment task
  # Environment-agnostic: dependencies don't include environment in name
  # Returns list of task names that must complete before this deployment
  # Dependencies should reference the post-deploy task (which triggers the full chain)
  buildDeployDependencies = serviceName: service:
    let
      # Dependencies on other services' post-deploy tasks (full deployment chain)
      serviceDeps = map (dep: "saas-post-deploy:${dep}") service.dependencies;

      allDeps = serviceDeps;
    in
    allDeps;

  # Build dependency list for a secret export task
  # Environment-agnostic: dependencies don't include environment in name
  buildSecretExportDependencies = exportName: exportConfig:
    let
      # Dependencies on other secret exports (no environment in name)
      exportDeps = map (dep: "saas-secret-export:${dep}") exportConfig.dependencies;
    in
    exportDeps;
}
