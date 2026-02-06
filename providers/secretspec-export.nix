{ pkgs, lib, config }:

{
  # Provision provider interface for secretspec export
  # Runs as part of service provisioning to export secrets to target providers

  # provisionConfig: The config block from provision.providers array entry
  # servicePath: Inherited from main providerConfig.path
  # environment: Runtime environment name (e.g., "local", "edge", "production")
  # serviceConfig: Full service configuration (not used by secretspec but kept for consistency)
  provision = serviceName: provisionConfig: servicePath: environment: serviceConfig: ''
        echo "  📦 [secretspec] Exporting secrets for ${serviceName}/${environment}"

        # Ensure bun global bin is in PATH (for zuplo CLI)
        export PATH="$HOME/.bun/bin:$PATH"

        # Install zuplo CLI if not available (needed for zuplo:// targets)
        # Note: @zuplo/cli installs binary as 'zup', so we create a 'zuplo' symlink
        if ! command -v zuplo &> /dev/null; then
          echo "  📥 Installing Zuplo CLI..."
          ${pkgs.bun}/bin/bun install -g @zuplo/cli || {
            echo "  ❌ Failed to install Zuplo CLI"
            exit 1
          }
          # Create zuplo symlink pointing to zup
          if [ -f "$HOME/.bun/bin/zup" ] && [ ! -f "$HOME/.bun/bin/zuplo" ]; then
            ln -s "$HOME/.bun/bin/zup" "$HOME/.bun/bin/zuplo"
          fi
        fi

        # Get secretSource and secretTarget with environment overrides and fallbacks
        SECRET_SOURCE="${provisionConfig.secretSource or "saas-controller"}"
        SECRET_TARGET="${provisionConfig.secretTarget or ""}"

        # Get include/exclude filter patterns (optional)
        INCLUDE_PATTERN="${provisionConfig.include or ""}"
        EXCLUDE_PATTERN="${provisionConfig.exclude or ""}"

        # Apply environment-specific overrides if they exist
        ${lib.optionalString (provisionConfig.environments or { } != { }) ''
          ${lib.concatStringsSep "\n    " (lib.mapAttrsToList (envName: envOverride: ''
            if [ "${environment}" = "${envName}" ]; then
              ${lib.optionalString (envOverride.secretSource or null != null) ''
                SECRET_SOURCE="${envOverride.secretSource}"
              ''}
              ${lib.optionalString (envOverride.secretTarget or null != null) ''
                SECRET_TARGET="${envOverride.secretTarget}"
              ''}
              ${lib.optionalString (envOverride.include or null != null) ''
                INCLUDE_PATTERN="${envOverride.include}"
              ''}
              ${lib.optionalString (envOverride.exclude or null != null) ''
                EXCLUDE_PATTERN="${envOverride.exclude}"
              ''}
            fi
          '') (provisionConfig.environments or { }))}
        ''}

        if [ -z "$SECRET_TARGET" ]; then
          echo "  ❌ Error: secretTarget not specified for ${serviceName}"
          exit 1
        fi

        # Profile name is always the environment name
        PROFILE="${environment}"

        # Check if secretspec.toml exists
        # Allow path override from provisionConfig, otherwise use servicePath
        SECRETSPEC_DIR="${provisionConfig.path or servicePath}"
        SECRETSPEC_PATH="${config.git.root}/$SECRETSPEC_DIR/secretspec.toml"
        if [ ! -f "$SECRETSPEC_PATH" ]; then
          echo "  ❌ Error: secretspec.toml not found at $SECRETSPEC_PATH"
          exit 1
        fi

        # Change to the directory containing secretspec.toml
        cd ${config.git.root}/$SECRETSPEC_DIR

        # Check secrets before export
        echo "  🔍 Checking secrets for $SECRET_SOURCE/$PROFILE..."
        if ! ${pkgs.secretspec}/bin/secretspec check \
          --provider "$SECRET_SOURCE" \
          --profile "$PROFILE"; then
          echo "  ❌ Error: Missing required secrets for $PROFILE"
          echo "  Run: secretspec check --provider $SECRET_SOURCE --profile $PROFILE"
          exit 1
        fi
        echo "  ✓ All secrets present"

        echo "  Source: $SECRET_SOURCE/$PROFILE"
        echo "  Target: $SECRET_TARGET"

        # Build filter flags
        FILTER_FLAGS=""
        if [ -n "$INCLUDE_PATTERN" ]; then
          FILTER_FLAGS="$FILTER_FLAGS --include $INCLUDE_PATTERN"
          echo "  Include filter: $INCLUDE_PATTERN"
        fi
        if [ -n "$EXCLUDE_PATTERN" ]; then
          FILTER_FLAGS="$FILTER_FLAGS --exclude $EXCLUDE_PATTERN"
          echo "  Exclude filter: $EXCLUDE_PATTERN"
        fi

        # Export secrets using updated secretspec with --provider, --profile, and filter flags
        # Control plane credentials (ZUPLO_API_KEY) are provided by outer wrapper
        echo "  Running: secretspec export $SECRET_TARGET --provider $SECRET_SOURCE --profile $PROFILE$FILTER_FLAGS --force"
        ${pkgs.secretspec}/bin/secretspec export "$SECRET_TARGET" --provider "$SECRET_SOURCE" --profile "$PROFILE" $FILTER_FLAGS --force

        echo "  ✓ Secrets exported successfully"

        # Write output file for dependent services
        mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
        cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}-secretspec.json <<EOF
    {
      "serviceName": "${serviceName}",
      "environment": "${environment}",
      "provisionProvider": "secretspec",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "outputs": {
        "profile": "$PROFILE",
        "secretTarget": "$SECRET_TARGET",
        "secretSource": "$SECRET_SOURCE",
        "path": "$SECRETSPEC_DIR",
        "includeFilter": "$INCLUDE_PATTERN",
        "excludeFilter": "$EXCLUDE_PATTERN"
      },
      "metadata": {
        "exportedBy": "''${USER:-unknown}",
        "gitCommit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
        "gitBranch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
      }
    }
    EOF
  '';
}
