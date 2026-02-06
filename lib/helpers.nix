{ pkgs, lib, config, providers }:

let
  # Helper function to get enabled environments
  getEnabledEnvironments = service:
    lib.filterAttrs (_: env: env.enable) service.environments;

  # Run hooks for a service (pre-deploy or post-deploy)
  # Orchestrates all hooks (secretspec, frontegg, datadog) in order
  # Args:
  #   serviceName: Name of the service
  #   service: Full service configuration
  #   hooks: List of hook configurations
  #   hookPhase: "pre" or "post" (for logging)
  #   environment: Runtime environment name
  # Returns: Bash script that runs all hooks
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
          hookCmd = hookProvider.provision serviceName hookConfig.config servicePath environment service;
        in ''
          echo ""
          echo "  [${toString (index + 1)}/${toString (builtins.length hooks)}] Running ${hookType} hook..."
          cd ${config.git.root}/stacks/${serviceName}
          bash -c ${lib.escapeShellArg "set -e; ${hookCmd}"} || {
            echo "  ❌ hook failed (exit code: $?)"
            exit 1
          }
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

          # Run export for the matching environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: envConfig:
            let
              # Get raw command from provider — credentials must be in the environment
              rawCommand = provider.deploy exportName exportConfig envName envConfig envName "env";
            in ''
              if [ "$ENV" = "${envName}" ]; then
                cd ${config.git.root}/stacks/${exportName}
                bash -c ${lib.escapeShellArg "set -e; ${rawCommand}"} || {
                  echo "  ❌ Export failed (exit code: $?)"
                  exit 1
                }
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
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

          # Run deployment for the matching environment — credentials must be in the environment
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList (envName: envConfig:
            let
              # Get raw command from provider
              rawCommand = provider.deploy serviceName service envName envConfig envName "env";
            in ''
              if [ "$ENV" = "${envName}" ]; then
                (
                  cd ${config.git.root}/stacks/${serviceName}
                  bash -c ${lib.escapeShellArg "set -e; ${rawCommand}"} || {
                    echo ""
                    echo "❌ Deployment failed for ${serviceName} in environment $ENV"
                    exit 1
                  }
                )
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
              --argjson provider_data "$(cat "$PROVIDER_OUTPUT_FILE")" \
              '{
                service: $service,
                environment: $env,
                status: "success",
                action: $action,
                timestamp: $timestamp,
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
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
            "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
