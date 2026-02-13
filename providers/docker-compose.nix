# Provider: docker-compose
#
# Accepts a pre-authored docker-compose.yml and injects a tailscale sidecar
# via Docker Compose multi-file merge (overlay). App services get
# network_mode: service:tailscale added automatically.
#
# Usage in your devenv.nix:
#   saas-controller.services.miniflux = {
#     enable = true;
#     provider = "docker-compose";
#     providerConfig = {
#       path = "services/miniflux";           # dir containing docker-compose.yml
#       # composeFile = "docker-compose.yml"; # optional override
#       tailscale = [
#         { port = 443; upstream = "http://127.0.0.1:8080"; }
#       ];
#     };
#     environments.local.enable = true;
#   };

{ pkgs, lib, config }:

let
  compose = import ../lib/docker-compose.nix { inherit lib config; };

  # Convert an SA token alias to its environment variable name.
  # "client-willdan" -> "OP_SA_CLIENT_WILLDAN"
  toSASecretName = name:
    "OP_SA_${lib.toUpper (builtins.replaceStrings ["-"] ["_"] name)}";

  # Shared Nix-time setup for a service. Returns an attrset of derived values
  # used by both `up` and `deploy`.
  mkSetup = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";
      composeFile = service.providerConfig.composeFile or "docker-compose.yml";
      tailscaleEntries = service.providerConfig.tailscale or [
        { port = 443; upstream = "http://127.0.0.1:8080"; }
      ];

      serveContent = compose.mkServeConfig tailscaleEntries;

      # The tailscale sidecar service for the overlay.
      # Volume paths are absolute because --project-directory points to sourceDir.
      sidecarYaml = lib.concatStringsSep "\n" [
        "services:"
        "  tailscale:"
        "    image: tailscale/tailscale:latest"
        "    hostname: \${TS_HOSTNAME}"
        "    environment:"
        "      - TS_HOSTNAME=\${TS_HOSTNAME}"
        "      - TS_AUTHKEY=\${TS_CLIENT_SECRET}?ephemeral=true"
        "      - TS_EXTRA_ARGS=--advertise-tags=tag:sc-dev"
        "      - TS_SERVE_CONFIG=/config/serve.json"
        "      - TS_STATE_DIR=/var/lib/tailscale"
        "      - TS_USERSPACE=false"
        "    volumes:"
        "      - ${composeDir}/serve-config.json:/config/serve.json:ro"
        "      - ts-state:/var/lib/tailscale"
        "    cap_add:"
        "      - NET_ADMIN"
        "    devices:"
        "      - /dev/net/tun:/dev/net/tun"
        "    healthcheck:"
        "      test: [\"CMD\", \"tailscale\", \"status\"]"
        "      interval: 2s"
        "      timeout: 5s"
        "      retries: 10"
        ""
        "volumes:"
        "  ts-state:"
      ];

      composeFiles = [
        "app-compose.yml"
        "tailscale-sidecar.yml"
        "tailscale-overlay.yml"
      ];

      composeCmd = compose.mkComposeCommand {
        inherit composeDir composeFiles;
        projectDir = sourceDir;
      };

      # Bash script that generates all compose files in composeDir.
      # Expects SC_SLUG and SC_TAILNET to be set by caller.
      setupScript = ''
        mkdir -p "${composeDir}"

        # Compute tailscale hostname and FQDN (exported for docker-compose interpolation)
        export TS_HOSTNAME="sc-$SC_SLUG-${serviceName}"
        export FQDN="$TS_HOSTNAME.$SC_TAILNET"

        # Write serve-config.json
        ${compose.writeFile "${composeDir}/serve-config.json" serveContent}

        # Write the tailscale sidecar base overlay
        ${compose.writeFile "${composeDir}/tailscale-sidecar.yml" sidecarYaml}

        # Symlink the original compose file into composeDir
        ORIGINAL="${sourceDir}/${composeFile}"
        if [ ! -f "$ORIGINAL" ]; then
          echo "Error: Compose file not found: $ORIGINAL" >&2
          exit 1
        fi
        ln -sf "$ORIGINAL" "${composeDir}/app-compose.yml"

        # Auto-detect app service names and generate network_mode overlay
        APP_SERVICES=$(docker compose -f "$ORIGINAL" config --services 2>/dev/null)
        if [ -z "$APP_SERVICES" ]; then
          echo "Error: No services found in $ORIGINAL" >&2
          exit 1
        fi

        {
          echo "services:"
          for svc in $APP_SERVICES; do
            echo "  $svc:"
            echo "    network_mode: service:tailscale"
            echo "    depends_on:"
            echo "      tailscale:"
            echo "        condition: service_healthy"
          done
        } > "${composeDir}/tailscale-overlay.yml"
      '';
    in
    { inherit composeDir sourceDir composeFile composeFiles composeCmd
              tailscaleEntries serveContent sidecarYaml setupScript; };

in
{
  # Local dev lifecycle: overlay tailscale sidecar onto pre-authored compose
  up = serviceName: service:
    let
      s = mkSetup serviceName service;
    in
    ''
      set -euo pipefail

      ${s.setupScript}

      export DEVSERVER_URL="https://$FQDN:443"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      ${compose.mkComposeLifecycle {
        composeDir = s.composeDir;
        inherit serviceName;
        projectDir = s.sourceDir;
        composeFiles = s.composeFiles;
        urls = map (e: {
          label = "HTTPS :${toString e.port}";
          url = "https://$FQDN:${toString e.port}";
        }) s.tailscaleEntries;
      }}
    '';

  # docker-compose provider doesn't manage cloud projects
  provisionProject = serviceName: service: ''
    echo "  docker-compose: nothing to provision"
    echo "  ✓ Project ready"
  '';

  # Deploy as persistent OS service (launchd on macOS, systemd on Linux)
  deploy = serviceName: service: environment: envConfig: profile: provider:
    let
      s = mkSetup serviceName service;
      deployDir = "${config.git.root}/.saas-controller/deploy/${serviceName}";
      logDir = "${config.git.root}/.saas-controller/logs";
      wrapperScript = "${s.composeDir}/sc-service.sh";

      hasSecretspec = service.secretspec != null;
      secretspecDir = "${config.git.root}/.saas-controller/secretspec/${serviceName}";
      hasSAToken = hasSecretspec && service.secretspec.saToken != null;
      saSecretName = if hasSAToken then toSASecretName service.secretspec.saToken else "";
      saTokensDir = config.saas-controller.saTokensDir;

      # SA token swap snippet for wrapper script
      saSwapSnippet = lib.optionalString hasSAToken ''
        # SA token swap: retrieve ${saSecretName} from keyring
        SA_TOKEN="$(cd "${saTokensDir}" && ${pkgs.secretspec}/bin/secretspec get --provider keyring --profile default ${saSecretName})"
        if [ -z "$SA_TOKEN" ]; then
          echo "Failed to retrieve ${saSecretName} from keyring for ${serviceName}." >&2
          echo "Run 'store-sa-tokens' to populate SA tokens in the keyring." >&2
          exit 1
        fi
        export OP_SERVICE_ACCOUNT_TOKEN="$SA_TOKEN"
      '';

      # The command the wrapper runs to start the compose stack
      startCmd = if hasSecretspec then ''
        cd "${secretspecDir}"
        exec ${pkgs.secretspec}/bin/secretspec run --profile "${environment}" -- ${s.composeCmd} up -d --build --wait
      '' else ''
        exec ${s.composeCmd} up -d --build --wait
      '';

      launchdLabel = "com.saas-controller.${serviceName}";
      systemdUnit = "saas-controller-${serviceName}";
    in
    ''
      set -euo pipefail

      echo "  docker-compose: deploying ${serviceName} as persistent service"

      # --- Hostname derivation (same as sc up) ---
      if [ -n "''${VK_WORKSPACE_ID:-}" ]; then
        SC_SLUG="''${VK_WORKSPACE_ID:0:8}"
      else
        SC_SLUG="local"
      fi
      export SC_SLUG

      # --- Tailnet discovery ---
      if [ -z "''${SC_TAILNET:-}" ]; then
        if tailscale status --json >/dev/null 2>&1; then
          SC_TAILNET="$(tailscale status --json | ${pkgs.jq}/bin/jq -r '.MagicDNSSuffix')"
        fi
      fi
      if [ -z "''${SC_TAILNET:-}" ]; then
        echo "  Error: Cannot determine tailnet." >&2
        echo "    Set SC_TAILNET or install Tailscale on the host." >&2
        exit 1
      fi
      export SC_TAILNET

      # --- Generate compose files ---
      ${s.setupScript}

      # --- Generate wrapper script ---
      mkdir -p "${logDir}" "${deployDir}"

      cat > "${wrapperScript}" <<'__SC_WRAPPER_EOF'
      #!/usr/bin/env bash
      set -euo pipefail
      export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

      # Hostname (baked at deploy time)
      export TS_HOSTNAME="__PLACEHOLDER_TS_HOSTNAME__"
      export FQDN="__PLACEHOLDER_FQDN__"

      ${saSwapSnippet}
      ${startCmd}
      __SC_WRAPPER_EOF

      # Bake runtime values into wrapper (replacing placeholders)
      ${pkgs.gnused}/bin/sed -i \
        -e "s|__PLACEHOLDER_TS_HOSTNAME__|$TS_HOSTNAME|g" \
        -e "s|__PLACEHOLDER_FQDN__|$FQDN|g" \
        "${wrapperScript}"

      chmod +x "${wrapperScript}"

      # --- Install platform service ---
      PLATFORM="$(uname -s)"

      case "$PLATFORM" in
        Darwin)
          echo "  Installing launchd agent: ${launchdLabel}"

          # Unload existing if present
          launchctl bootout "gui/$(id -u)/${launchdLabel}" 2>/dev/null || true

          PLIST_PATH="$HOME/Library/LaunchAgents/${launchdLabel}.plist"

          cat > "$PLIST_PATH" <<PLIST_EOF
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>${launchdLabel}</string>
        <key>ProgramArguments</key>
        <array>
          <string>/bin/bash</string>
          <string>${wrapperScript}</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
          <key>SuccessfulExit</key>
          <false/>
        </dict>
        <key>StandardOutPath</key>
        <string>${logDir}/${serviceName}.stdout.log</string>
        <key>StandardErrorPath</key>
        <string>${logDir}/${serviceName}.stderr.log</string>
        <key>WorkingDirectory</key>
        <string>${s.sourceDir}</string>
        <key>EnvironmentVariables</key>
        <dict>
          <key>PATH</key>
          <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
          <key>HOME</key>
          <string>$HOME</string>
        </dict>
      </dict>
      </plist>
      PLIST_EOF

          launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

          echo "  Launchd agent installed and started"
          echo "  Logs: ${logDir}/${serviceName}.stdout.log"
          echo "  Stop: sc undeploy ${serviceName}"
          ;;

        Linux)
          echo "  Installing systemd user service: ${systemdUnit}"

          UNIT_DIR="$HOME/.config/systemd/user"
          mkdir -p "$UNIT_DIR"

          cat > "$UNIT_DIR/${systemdUnit}.service" <<UNIT_EOF
      [Unit]
      Description=SaaS Controller: ${serviceName}
      After=docker.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/bash ${wrapperScript}
      ExecStop=${s.composeCmd} down
      StandardOutput=append:${logDir}/${serviceName}.stdout.log
      StandardError=append:${logDir}/${serviceName}.stderr.log
      WorkingDirectory=${s.sourceDir}

      [Install]
      WantedBy=default.target
      UNIT_EOF

          systemctl --user daemon-reload
          systemctl --user enable --now "${systemdUnit}"

          echo "  Systemd service installed and started"
          echo "  Logs: journalctl --user -u ${systemdUnit}"
          echo "  Stop: sc undeploy ${serviceName}"
          ;;

        *)
          echo "  Error: Unsupported platform: $PLATFORM" >&2
          exit 1
          ;;
      esac

      # --- Write deployment state ---
      cat > "${deployDir}/state.json" <<STATE_EOF
      {
        "serviceName": "${serviceName}",
        "environment": "${environment}",
        "platform": "$PLATFORM",
        "serviceIdentifier": "$([ "$PLATFORM" = "Darwin" ] && echo "${launchdLabel}" || echo "${systemdUnit}")",
        "wrapperScript": "${wrapperScript}",
        "composeDir": "${s.composeDir}",
        "composeCmd": ${lib.escapeShellArg s.composeCmd},
        "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "fqdn": "$FQDN"
      }
      STATE_EOF

      # --- Write deployment outputs ---
      mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
      cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
      {
        "service": "${serviceName}",
        "environment": "${environment}",
        "provider": "docker-compose",
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "outputs": {
          "url": "https://$FQDN:443",
          "serviceType": "$([ "$PLATFORM" = "Darwin" ] && echo "launchd" || echo "systemd")",
          "serviceIdentifier": "$([ "$PLATFORM" = "Darwin" ] && echo "${launchdLabel}" || echo "${systemdUnit}")"
        }
      }
      EOF

      echo "  ✓ Deployment successful"
      echo "  URL: https://$FQDN:443"
    '';
}
