# shellcheck shell=bash
# Load site configuration before expanding site-dependent defaults.
# Prerequisites: source from Bash; deploy/env/<site>/site.env or an explicit config file.
# ENV: SITE site name or SITE_ENV config path (one required; no default).
# Effects: sources site values into the caller environment.
# Exit: returns 0 on load; exits 1 for missing configuration.

if [ -z "${SITE_ENV:-}" ]; then
  if [ -z "${SITE:-}" ]; then
    echo "ERROR: no site selected. Set SITE=<name> (deploy/env/<name>/site.env) or SITE_ENV=<file>," >&2
    echo "       e.g. SITE=example for the example site. See deploy/env/README.md." >&2
    exit 1
  fi
  SITE_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/env/${SITE}/site.env"
fi
[ -f "${SITE_ENV}" ] || { echo "ERROR: site file not found: ${SITE_ENV}" >&2; exit 1; }
# shellcheck source=/dev/null
. "${SITE_ENV}"
export SITE_ENV
