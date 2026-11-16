# shellcheck shell=bash
# Refuse a client targeting the wrong cluster; source and call cluster_guard <hub|tenant> "<client>".
# Prerequisites: oc/kubectl; explicit --kubeconfig or KUBECONFIG, plus site EXPECT_*_API_SERVER.
# ENV: EXPECT_HUB_API_SERVER / EXPECT_TENANT_API_SERVER = required server URLs (no defaults).
# Effects: reads local kubeconfig only, including on dry runs; ignores a trailing server slash.
# Exit: returns 0 on match; exits 1 on missing or mismatched configuration.

_cg_die() { printf '\033[1;31mERROR (cluster-guard):\033[0m %s\n' "$*" >&2; exit 1; }

cluster_guard() {
  local role="${1:-}" cli="${2:-}" var want got
  case "${role}" in
    hub)    var=EXPECT_HUB_API_SERVER ;;
    tenant) var=EXPECT_TENANT_API_SERVER ;;
    *) _cg_die "unknown target cluster '${role}' (want hub or tenant; dual-use scripts read TARGET_CLUSTER)" ;;
  esac
  [ -n "${cli}" ] || _cg_die "no ${role} client set, e.g. OC='oc --kubeconfig=/path/to/${role}/kubeconfig'"
  case " ${cli} " in
    *" --kubeconfig"*) ;;
    *) [ -n "${KUBECONFIG:-}" ] \
         || _cg_die "${role} client '${cli}' has no --kubeconfig and KUBECONFIG is unset; refusing the ~/.kube/config default" ;;
  esac
  want="${!var:-}"
  [ -n "${want}" ] || _cg_die "${var} is not set (the ${role} API server URL, e.g. https://api.<cluster>.<domain>:6443)"
  got="$(${cli} config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" \
    || _cg_die "'${cli} config view' failed; is the kubeconfig readable?"
  [ "${got%/}" = "${want%/}" ] \
    || _cg_die "WRONG CLUSTER: '${cli}' targets ${got:-<nothing>} but ${var}=${want}"
  printf 'cluster-guard: %s client targets %s (as expected)\n' "${role}" "${got}" >&2
}
