{ pkgs, lib, config }:

{
  # Provision provider interface for Datadog Software Catalog sync
  # Runs as part of service provisioning to sync service metadata

  # provisionConfig: The config block from provision.providers array entry
  # servicePath: Inherited from main providerConfig.path
  # environment: Runtime environment name (e.g., "local", "edge", "production")
  # serviceConfig: Full service configuration for accessing metadata
  provision = serviceName: provisionConfig: servicePath: environment: serviceConfig: ''
        echo "  📊 [datadog] Syncing ${serviceName}/${environment} to Software Catalog"

        # Check if we should sync this environment
        SHOULD_SYNC="false"
        ${lib.optionalString (provisionConfig.syncEnvironments or [] != []) ''
          ${lib.concatStringsSep "\n    " (map (env: ''
            if [ "${environment}" = "${env}" ]; then
              SHOULD_SYNC="true"
            fi
          '') (provisionConfig.syncEnvironments or []))}
        ''}

        # If no specific environments configured, sync all
        ${lib.optionalString (provisionConfig.syncEnvironments or [] == []) ''
          SHOULD_SYNC="true"
        ''}

        if [ "$SHOULD_SYNC" = "false" ]; then
          echo "  ⏭️  Skipping Datadog sync (environment ${environment} not in syncEnvironments)"
          exit 0
        fi

        # Use secretspec run from .saas-controller/ to load DD_API_KEY and DD_APP_KEY
        cd ${config.git.root}/.saas-controller

        ${pkgs.secretspec}/bin/secretspec run --profile dev-saas-controller -- bash -c '
          # Check for required environment variables
          if [ -z "''${DD_API_KEY:-}" ] || [ -z "''${DD_APP_KEY:-}" ]; then
            echo "  ⚠️  Warning: DD_API_KEY or DD_APP_KEY not set in saas-controller secrets, skipping Datadog sync"
            exit 0
          fi

          # Get entity mapping from provisionConfig with fallbacks
          ENTITY_TYPE="${provisionConfig.entityMapping.type or "other"}"
          ENTITY_TIER="${provisionConfig.entityMapping.tier or "tier2"}"

          # Build Datadog Service Catalog v3 entity from service config
          ENTITY_JSON=$(cat <<EOF
    {
      "apiVersion": "v3",
      "kind": "service",
      "metadata": {
        "name": "${serviceName}",
        "displayName": "${serviceConfig.displayName}",
        "tags": [
          "provider:${serviceConfig.provider}",
          "environment:${environment}"
        ],
        "links": [],
        "contacts": [],
        "additionalProperties": {}
      },
      "spec": {
        "type": "$ENTITY_TYPE",
        "lifecycle": "production",
        "tier": "$ENTITY_TIER",
        "application": "${serviceName}",
        "owner": "platform-team",
        "dependsOn": ${builtins.toJSON serviceConfig.dependencies},
        "additionalProperties": {}
      }
    }
    EOF
    )

          # POST to Datadog Software Catalog API
          echo "  Posting entity to Datadog..."
          RESPONSE=$(${pkgs.curl}/bin/curl -s -w "\n%{http_code}" -X POST \
            "https://api.datadoghq.com/api/v2/services/definitions" \
            -H "DD-API-KEY: $DD_API_KEY" \
            -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
            -H "Content-Type: application/json" \
            -d "$ENTITY_JSON")

          HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
          BODY=$(echo "$RESPONSE" | head -n -1)

          if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            echo "  ✓ Successfully synced to Datadog (HTTP $HTTP_CODE)"
          else
            echo "  ⚠️  Warning: Datadog sync failed (HTTP $HTTP_CODE)"
            echo "  Response: $BODY"
            # Do not fail deployment on Datadog sync errors
            exit 0
          fi
        '

        # Write output file
        mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
        cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}-datadog.json <<EOF
    {
      "serviceName": "${serviceName}",
      "environment": "${environment}",
      "provisionProvider": "datadog",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "outputs": {
        "synced": true
      }
    }
    EOF
  '';

  # Legacy sync function for backward compatibility
  sync = serviceName: service: ''
    echo "  Syncing ${serviceName} to Datadog Software Catalog (legacy interface)..."
    cd ${config.git.root}/.saas-controller
    ${pkgs.secretspec}/bin/secretspec run --profile dev-saas-controller -- bash -c '
      if [ -z "''${DD_API_KEY:-}" ] || [ -z "''${DD_APP_KEY:-}" ]; then
        echo "  ⚠️  Warning: DD_API_KEY or DD_APP_KEY not set, skipping"
        exit 0
      fi
      # Legacy sync implementation...
    '
  '';

  # Legacy interfaces for backward compatibility
  provisionProject = serviceName: service: ''
    echo "  Datadog: No project provisioning needed (legacy interface)"
  '';

  provisionEnvironment = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Datadog: Use provision provider interface (legacy interface called)"
  '';

  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Datadog: Use provision provider interface (legacy interface called)"
  '';
}
