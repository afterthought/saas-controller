# Shared SA token swap snippet generator.
# Used by lib/helpers.nix (exported for devenv.nix) and providers/docker-compose.nix.
#
# Two modes:
#   failMode = "hard" (default): exit 1 if token is empty (operational commands: sc up, deploy, check-secrets)
#   failMode = "soft": silently skip if token is empty (status/reporting commands: setup-env, diff-secrets)
{ pkgs }:

{
  mkSASwapSnippet = { saSecretName, saTokensDir, serviceName, failMode ? "hard" }: ''
    SA_TOKEN="$(cd "${saTokensDir}" && ${pkgs.secretspec}/bin/secretspec get --provider sa-tokens --profile default ${saSecretName})"
  '' + (if failMode == "hard" then ''
    if [ -z "$SA_TOKEN" ]; then
      echo "Error: Failed to retrieve ${saSecretName} for ${serviceName}." >&2
      echo "  Check your SA token provider: secretspec config provider list" >&2
      echo "  To set up: secretspec config provider add sa-tokens 'keyring://'" >&2
      exit 1
    fi
    export OP_SERVICE_ACCOUNT_TOKEN="$SA_TOKEN"
  '' else ''
    if [ -n "$SA_TOKEN" ]; then export OP_SERVICE_ACCOUNT_TOKEN="$SA_TOKEN"; fi
  '');
}
