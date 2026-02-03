# Runtime: docker-compose
#
# Manages processes via docker compose.
# Port allocation uses Compose port mapping.
# Logs are streamed via `docker compose logs -f`.
#
# Status: STUB — documented interface, not yet implemented.
# To use this runtime, set:
#   saas-controller.defaultRuntime = "docker-compose";
# or per-service:
#   saas-controller.services.<name>.runtime = "docker-compose";
#
# Implementation notes:
# - Requires a docker-compose.yml in the service's working directory
# - Port should be exposed via Compose ports mapping
# - The $PORT variable is allocated by the caller and passed through
# - Network snippets are injected for URL exposure (Tailscale, localhost, etc.)

{ pkgs, lib }:

{
  name = "docker-compose";
  description = "Process management via docker compose (container-based)";
  requiredPackages = [ pkgs.docker-compose ];

  mkScript = { serviceName, service, variant, command, workingDir, config
              , networkSetup, networkCleanup, networkPrintUrl }:
    let
      scriptName = "dev-serve-${serviceName}-${variant}";
    in
    pkgs.writeShellScriptBin scriptName ''
      set -euo pipefail

      echo "Starting ${serviceName}-${variant} via docker-compose..."

      # TODO: Implement docker-compose runtime
      #
      # Expected flow:
      # 1. Generate or locate docker-compose.yml for this service
      # 2. Set PORT environment variable for the container
      # 3. Run: docker compose up -d
      # 4. Extract allocated port from compose config
      # 5. Run network setup (Tailscale/localhost)
      # 6. Stream logs via: docker compose logs -f
      # 7. On exit: docker compose down + network cleanup
      #
      # Example implementation:
      #
      # export PORT=''${PORT:-$(shuf -i 10000-65000 -n 1)}
      # cd ${lib.escapeShellArg workingDir}
      #
      # docker compose up -d
      #
      # cleanup() {
      #   echo "Stopping ${serviceName}-${variant}..."
      #   ${networkCleanup}
      #   docker compose down 2>/dev/null || true
      #   echo "Stopped."
      # }
      # trap cleanup EXIT INT TERM
      #
      # ${networkSetup}
      # ${networkPrintUrl}
      #
      # docker compose logs -f

      echo "ERROR: docker-compose runtime is not yet implemented." >&2
      echo "Use 'dev-manager-mcp' runtime instead:" >&2
      echo "  saas-controller.defaultRuntime = \"dev-manager-mcp\";" >&2
      exit 1
    '';
}
