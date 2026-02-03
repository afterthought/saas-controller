# Runtime: launchd
#
# Manages processes via macOS launchd (launchctl).
# Port allocation uses persistent port files.
# Logs are streamed via `tail -f` on launchd log files.
#
# Status: STUB — documented interface, not yet implemented.
# To use this runtime, set:
#   saas-controller.defaultRuntime = "launchd";
# or per-service:
#   saas-controller.services.<name>.runtime = "launchd";
#
# Implementation notes:
# - macOS only (launchctl is not available on Linux)
# - Generates a LaunchAgent plist in ~/Library/LaunchAgents/
# - Process survives terminal close (runs as a proper daemon)
# - Port is persisted to a file for cross-session access
# - Logs written to ~/Library/Logs/saas-controller/

{ pkgs, lib }:

{
  name = "launchd";
  description = "Process management via macOS launchd (persistent daemon)";
  requiredPackages = [ ];

  mkScript = { serviceName, service, variant, command, workingDir, config
              , networkSetup, networkCleanup, networkPrintUrl }:
    let
      scriptName = "dev-serve-${serviceName}-${variant}";
      plistLabel = "com.saas-controller.${serviceName}-${variant}";
    in
    pkgs.writeShellScriptBin scriptName ''
      set -euo pipefail

      echo "Starting ${serviceName}-${variant} via launchd..."

      # TODO: Implement launchd runtime
      #
      # Expected flow:
      # 1. Allocate or reuse a port (persist to ~/.saas-controller/ports/${serviceName}-${variant})
      # 2. Generate LaunchAgent plist at ~/Library/LaunchAgents/${plistLabel}.plist
      # 3. Load via: launchctl load ~/Library/LaunchAgents/${plistLabel}.plist
      # 4. Run network setup (Tailscale/localhost)
      # 5. Stream logs via: tail -f ~/Library/Logs/saas-controller/${serviceName}-${variant}.log
      # 6. On exit: launchctl unload + network cleanup
      #
      # Example plist structure:
      #
      # <?xml version="1.0" encoding="UTF-8"?>
      # <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
      # <plist version="1.0">
      # <dict>
      #   <key>Label</key>
      #   <string>${plistLabel}</string>
      #   <key>ProgramArguments</key>
      #   <array>
      #     <string>/bin/bash</string>
      #     <string>-c</string>
      #     <string>${command}</string>
      #   </array>
      #   <key>WorkingDirectory</key>
      #   <string>${workingDir}</string>
      #   <key>EnvironmentVariables</key>
      #   <dict>
      #     <key>PORT</key>
      #     <string>$PORT</string>
      #   </dict>
      #   <key>StandardOutPath</key>
      #   <string>$LOG_DIR/stdout.log</string>
      #   <key>StandardErrorPath</key>
      #   <string>$LOG_DIR/stderr.log</string>
      #   <key>RunAtLoad</key>
      #   <true/>
      # </dict>
      # </plist>
      #
      # Example implementation:
      #
      # PORT_FILE="$HOME/.saas-controller/ports/${serviceName}-${variant}"
      # LOG_DIR="$HOME/Library/Logs/saas-controller/${serviceName}-${variant}"
      # PLIST_PATH="$HOME/Library/LaunchAgents/${plistLabel}.plist"
      #
      # mkdir -p "$(dirname "$PORT_FILE")" "$LOG_DIR"
      # export PORT=''${PORT:-$(shuf -i 10000-65000 -n 1)}
      # echo "$PORT" > "$PORT_FILE"
      #
      # # Generate and load plist...
      # launchctl load "$PLIST_PATH"
      #
      # cleanup() {
      #   echo "Stopping ${serviceName}-${variant}..."
      #   ${networkCleanup}
      #   launchctl unload "$PLIST_PATH" 2>/dev/null || true
      #   echo "Stopped."
      # }
      # trap cleanup EXIT INT TERM
      #
      # ${networkSetup}
      # ${networkPrintUrl}
      #
      # tail -f "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"

      echo "ERROR: launchd runtime is not yet implemented." >&2
      echo "Use 'dev-manager-mcp' runtime instead:" >&2
      echo "  saas-controller.defaultRuntime = \"dev-manager-mcp\";" >&2
      exit 1
    '';
}
