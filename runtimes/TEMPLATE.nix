# Template for creating a custom SaaS Controller runtime
#
# Runtimes control HOW processes are managed (start, stop, log streaming).
# They are independent of network exposure (Tailscale, localhost, etc.)
# which is handled by network strategies injected via snippet arguments.
#
# To use this runtime:
# 1. Copy this file to your runtime .nix file
# 2. Implement mkScript
# 3. Register it:
#      saas-controller.externalRuntimes.my-runtime = ./my-runtime.nix;
# 4. Use it:
#      saas-controller.defaultRuntime = "my-runtime";
#    or per-service:
#      saas-controller.services.<name>.runtime = "my-runtime";

{ pkgs, lib }:

{
  # Runtime identifier (must match the attribute name used in registration)
  name = "my-runtime";

  # Human-readable description
  description = "My custom process runtime";

  # Packages required by this runtime (added to devenv packages)
  requiredPackages = [ ];

  # Create a dev-serve script for a service variant.
  #
  # Returns a pkgs.writeShellScriptBin derivation.
  #
  # Arguments:
  #   serviceName   - Name of the service (e.g., "willdan-dev-gateway")
  #   service       - Full service configuration attrset
  #   variant       - Variant name (e.g., "api", "docs")
  #   command       - Shell command to run the service (includes secretspec wrapping)
  #   workingDir    - Absolute path to the service directory
  #   config        - devenv config (for accessing git.root, etc.)
  #
  # Network snippets (bash strings, injected by the dispatcher):
  #   networkSetup    - Called after $PORT is set. Must set $DEVSERVER_URL.
  #   networkCleanup  - Called in trap handler (deregister network exposure).
  #   networkPrintUrl - Echo the URL to stdout.
  #
  # Contract:
  #   1. Script must set $PORT before calling networkSetup
  #   2. Script must call networkSetup, then networkPrintUrl
  #   3. Script must register a trap that calls networkCleanup
  #   4. Script should stream logs to stdout/stderr
  #   5. Script should exit non-zero if the service dies unexpectedly
  mkScript = { serviceName, service, variant, command, workingDir, config
              , networkSetup, networkCleanup, networkPrintUrl }:
    let
      scriptName = "dev-serve-${serviceName}-${variant}";
    in
    pkgs.writeShellScriptBin scriptName ''
      set -euo pipefail

      echo "Starting ${serviceName}-${variant}..."

      # Step 1: Start the process and allocate a port
      # The runtime decides how to manage the process lifecycle.
      # $PORT must be set before calling networkSetup.
      export PORT=''${PORT:-$(shuf -i 10000-65000 -n 1)}

      # TODO: Start your process here
      # Examples:
      #   - Fork a background process
      #   - Start a container
      #   - Load a systemd/launchd unit

      # Step 2: Register cleanup handler
      cleanup() {
        echo ""
        echo "Stopping ${serviceName}-${variant}..."
        ${networkCleanup}
        # TODO: Stop your process here
        echo "Stopped."
      }
      trap cleanup EXIT INT TERM

      # Step 3: Network setup (register port, set DEVSERVER_URL)
      ${networkSetup}
      ${networkPrintUrl}

      # Step 4: Stream logs (blocking — keeps the script alive)
      # TODO: Tail your process logs here
      # The script should block until interrupted or the process exits.
      while true; do
        sleep 2
        # TODO: Check if process is still running
        # TODO: Forward new log output
      done
    '';
}
