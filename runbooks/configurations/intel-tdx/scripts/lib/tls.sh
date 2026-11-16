# shellcheck shell=bash
# Resolve TLS trust after sourcing lib/site.sh: tls_ca <CA_VAR> <INSECURE_VAR> <what>.
# Prerequisites: a readable trusted CA file unless verification is explicitly disabled.
# ENV: caller-named CA variable (required); caller-named INSECURE variable (false).
# Effects: sets TLS_CA; an explicit true disables verification and prints a warning.
# Exit: returns 0 on resolution; exits 1 on missing trust.

tls_ca() {
  local ca="${!1:-}" insecure="${!2:-false}"
  TLS_CA=""
  if [ "${insecure}" = "true" ]; then
    printf '\033[1;33mWARN:\033[0m %s=true: TLS verification of %s is OFF (set %s to its CA bundle instead).\n' "$2" "$3" "$1" >&2
    return 0
  fi
  if [ -z "${ca}" ] || [ ! -r "${ca}" ]; then
    local why="not set"; [ -z "${ca}" ] || why="'${ca}' is not a readable file"
    printf '\033[1;31mERROR:\033[0m TLS verification of %s needs its CA bundle: %s %s.\n' "$3" "$1" "${why}" >&2
    printf '  Set %s (deploy/env/<site>/site.env or the environment) to the PEM CA bundle that signs it,\n  or set %s=true to skip verification (not recommended).\n' "$1" "$2" >&2
    exit 1
  fi
  TLS_CA="${ca}"
}
