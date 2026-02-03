# Runtime: dev-manager-mcp
#
# Manages processes via mcporter → dev-manager-mcp daemon.
# Port allocation is dynamic (assigned by the daemon).
# Logs are polled via dev-manager.tail every 2 seconds.
#
# Extracted from the original mkDevServeScript in helpers.nix.

{ pkgs, lib }:

{
  name = "dev-manager-mcp";
  description = "Process management via dev-manager-mcp daemon (mcporter)";
  requiredPackages = [ ]; # mcporter is invoked via npx

  # Returns a writeShellScriptBin derivation
  mkScript = { serviceName, service, variant, command, workingDir, config
              , networkSetup, networkCleanup, networkPrintUrl }:
    let
      scriptName = "dev-serve-${serviceName}-${variant}";
    in
    pkgs.writeShellScriptBin scriptName ''
      set -euo pipefail

      # Build the command with environment passthrough
      # dev-manager-mcp spawns commands outside devenv, so we need to:
      # 1. Pass OP_SERVICE_ACCOUNT_TOKEN for 1Password auth
      # 2. Wrap in devenv shell for full PATH (op, bun, etc.)
      ENV_PREFIX=""
      if [ -n "''${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        ENV_PREFIX="OP_SERVICE_ACCOUNT_TOKEN=$OP_SERVICE_ACCOUNT_TOKEN "
      fi
      SPAWN_CMD="''${ENV_PREFIX}${pkgs.devenv}/bin/devenv shell -- ${command}"

      echo "Starting ${serviceName}-${variant}..."

      # Start the service via dev-manager-mcp (session_key is auto-generated)
      START_RESULT=$(npx -y mcporter call dev-manager.start \
        command="$SPAWN_CMD" \
        cwd=${lib.escapeShellArg workingDir}) || {
        echo "Failed to start service via dev-manager-mcp" >&2
        exit 1
      }

      # Extract session key and allocated port from result
      SESSION_KEY=$(echo "$START_RESULT" | ${pkgs.jq}/bin/jq -r '.session_key // empty')
      PORT=$(echo "$START_RESULT" | ${pkgs.jq}/bin/jq -r '.port // empty')
      export PORT

      if [ -z "$SESSION_KEY" ] || [ -z "$PORT" ]; then
        echo "Failed to start service — missing session_key or port" >&2
        echo "$START_RESULT" >&2
        exit 1
      fi

      echo "Started: session=$SESSION_KEY port=$PORT"

      # Cleanup handler: deregister network and stop the process
      cleanup() {
        echo ""
        echo "Stopping ${serviceName}-${variant}..."
        ${networkCleanup}
        npx -y mcporter call dev-manager.stop session_key="$SESSION_KEY" 2>/dev/null || true
        echo "Stopped."
      }
      trap cleanup EXIT INT TERM

      # Network setup (register port, set DEVSERVER_URL)
      ${networkSetup}
      ${networkPrintUrl}

      # Blocking tail loop — forward service logs until interrupted
      PREV_STDOUT_LEN=0
      PREV_STDERR_LEN=0
      while true; do
        sleep 2

        # Check if process is still running
        STATUS=$(npx -y mcporter call dev-manager.status session_key="$SESSION_KEY" 2>/dev/null) || true
        IS_RUNNING=$(echo "$STATUS" | ${pkgs.jq}/bin/jq -r '.running // false' 2>/dev/null)

        # Get cumulative logs and print only new content
        TAIL_RESULT=$(npx -y mcporter call dev-manager.tail session_key="$SESSION_KEY" 2>/dev/null) || true
        if [ -n "$TAIL_RESULT" ]; then
          STDOUT=$(echo "$TAIL_RESULT" | ${pkgs.jq}/bin/jq -r '.stdout // empty')
          STDERR=$(echo "$TAIL_RESULT" | ${pkgs.jq}/bin/jq -r '.stderr // empty')

          # Print new stdout content (tail returns cumulative output)
          CUR_STDOUT_LEN=''${#STDOUT}
          if [ "$CUR_STDOUT_LEN" -gt "$PREV_STDOUT_LEN" ]; then
            echo "''${STDOUT:$PREV_STDOUT_LEN}"
            PREV_STDOUT_LEN=$CUR_STDOUT_LEN
          fi

          # Print new stderr content
          CUR_STDERR_LEN=''${#STDERR}
          if [ "$CUR_STDERR_LEN" -gt "$PREV_STDERR_LEN" ]; then
            echo "''${STDERR:$PREV_STDERR_LEN}" >&2
            PREV_STDERR_LEN=$CUR_STDERR_LEN
          fi
        fi

        if [ "$IS_RUNNING" != "true" ]; then
          echo "Service ${serviceName}-${variant} exited unexpectedly." >&2
          exit 1
        fi
      done
    '';
}
