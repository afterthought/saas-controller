# Network strategies for dev-serve scripts
#
# Each network strategy provides bash snippet strings that are injected into
# runtime scripts. The runtime calls these at the right lifecycle points.
#
# Interface:
#   setup    — called after $PORT is set; must set $DEVSERVER_URL
#   cleanup  — called in trap handler (deregister/teardown)
#   printUrl — echo the URL to stdout

{ pkgs, lib }:

{
  # Tailscale HTTPS: register port on the tailnet for remote access
  tailscale = {
    name = "tailscale";
    description = "Expose service via Tailscale HTTPS on the tailnet";
    requiredPackages = [ ]; # tailscale is expected to be installed on the host

    setup = ''
      # Register with Tailscale serve for HTTPS access (--bg for background mode)
      tailscale serve --bg --https="$PORT" "http://127.0.0.1:$PORT" 2>/dev/null || true
      HOSTNAME=$(tailscale status --self --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.Self.DNSName // empty' | sed 's/\.$//')
      if [ -n "$HOSTNAME" ]; then
        DEVSERVER_URL="https://''${HOSTNAME}:''${PORT}"
      else
        DEVSERVER_URL="http://127.0.0.1:''${PORT}"
      fi
    '';

    cleanup = ''
      if [ -n "''${PORT:-}" ]; then
        tailscale serve --bg --https="$PORT" off 2>/dev/null || true
      fi
    '';

    printUrl = ''
      echo "DEVSERVER_URL: $DEVSERVER_URL"
    '';
  };

  # Localhost-only: no external exposure, just local access
  localhost = {
    name = "localhost";
    description = "Local-only access on 127.0.0.1 (no external exposure)";
    requiredPackages = [ ];

    setup = ''
      DEVSERVER_URL="http://127.0.0.1:''${PORT}"
    '';

    cleanup = ''
      # No network cleanup needed for localhost
      true
    '';

    printUrl = ''
      echo "DEVSERVER_URL: $DEVSERVER_URL"
    '';
  };
}
