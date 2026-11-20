#!/usr/bin/env python3

"""Registry credential rules for the dedicated TDX credential (site TDX_REGISTRY_AUTH_FILE).

Shared by scripts/tenant/00 (node pull secret), scripts/tenant/02 (ArgoCD repo credential) and
the hub Vault loader.

  check FILE                   exit 1 unless FILE is a dockerconfigjson whose users all look
                               read-only (no admin/root/init/superuser user, best effort)
  merge BASE TDX               print BASE with each TDX entry set under its exact key (host/org),
                               unless BASE holds that key for a different user. Other keys of
                               BASE (IBM's, even on the same host) are never replaced or dropped.
  repo-creds SECRET TDX URL    print the ArgoCD repo-creds Secret SECRET (JSON) with its
                               username/password replaced by the TDX entry that best matches URL
  lacks TDX REPO...            print each REPO (host/org) that TDX has no entry for (neither
                               host/org nor host). Empty output: all covered
  mirrors TOML IMAGE...        print the mirror host/org that guests pull IMAGE through, in the
                               order image-rs tries them (registry-configuration.toml)

Output JSON is compact with sorted keys, the same bytes as sprig toRawJson. Secrets go only to
stdout or files, never to argv or stderr.
"""
import base64
import json
import re
import sys

ADMIN = re.compile(r"(?i)admin|^(root|init|superuser)$")


def dump(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def load_auths(path):
    try:
        auths = json.load(open(path)).get("auths")
    except (OSError, ValueError, AttributeError) as e:
        sys.exit(f"{path}: not a dockerconfigjson ({e.__class__.__name__})")
    if not isinstance(auths, dict):
        sys.exit(f"{path}: no 'auths' object")
    return auths


def user_pass(entry):
    if entry.get("auth"):
        u, _, p = base64.b64decode(entry["auth"]).decode().partition(":")
        return u, p
    return entry.get("username", ""), entry.get("password", "")


def check(path):
    auths = load_auths(path)
    if not auths:
        sys.exit(f"{path}: no registry entries")
    for key, entry in auths.items():
        user = user_pass(entry)[0]
        if not user or ADMIN.search(user):
            sys.exit(f"{path}: entry {key} has user '{user}', which looks like an admin or is empty."
                     " Use a read-only robot (scripts/create-tdx-registry-credentials.sh).")


def merge(base_path, tdx_path):
    """Exact-key merge. A TDX key absent from BASE is added; a TDX key whose BASE entry has the
    same user (our robot, e.g. after ROTATE=true) gets the new token; a key held by another user
    stays. Keys that are not in the TDX file are never touched, even on the same host."""
    base = json.load(open(base_path))
    auths = base.setdefault("auths", {})
    for key, entry in load_auths(tdx_path).items():
        if key not in auths or user_pass(auths[key])[0] == user_pass(entry)[0]:
            auths[key] = entry
    return base


def best_entry(auths, url):
    """The entry for url, most specific key first (host/org/repo, host/org, host), like image-rs."""
    parts = url.split("://")[-1].split("/")
    for i in range(len(parts), 0, -1):
        if "/".join(parts[:i]) in auths:
            return auths["/".join(parts[:i])]
    sys.exit(f"the TDX registry credential has no entry for {url}")


def lacks(tdx_path, repos):
    """The robots are per org, so an entry for host/org or for the whole host covers a repo."""
    auths = load_auths(tdx_path)
    return [r for r in repos if r not in auths and r.split("/")[0] not in auths]


def mirrors(toml_path, image):
    """host/org of each mirror of the longest registry prefix that matches image."""
    import tomllib
    try:
        regs = tomllib.load(open(toml_path, "rb")).get("registry", [])
    except (OSError, ValueError) as e:
        sys.exit(f"{toml_path}: not a registry configuration ({e.__class__.__name__})")
    name = image.split("@")[0]
    hits = [r for r in regs if name == r.get("prefix") or name.startswith(r.get("prefix", "") + "/")]
    if not hits:
        return []
    best = max(hits, key=lambda r: len(r["prefix"]))
    return ["/".join(m["location"].split("/")[:2]) for m in best.get("mirror", [])]


def repo_creds(secret_path, tdx_path, url):
    secret = json.load(open(secret_path))
    u, p = user_pass(best_entry(load_auths(tdx_path), url))
    b64 = lambda s: base64.b64encode(s.encode()).decode()
    secret.setdefault("data", {}).update(username=b64(u), password=b64(p))
    secret.pop("stringData", None)
    return secret


if __name__ == "__main__":
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    if cmd == "check" and len(args) == 1:
        check(args[0])
    elif cmd == "merge" and len(args) == 2:
        check(args[1])
        print(dump(merge(*args)))
    elif cmd == "lacks" and len(args) >= 2:
        print(*lacks(args[0], args[1:]), sep="\n") if lacks(args[0], args[1:]) else None
    elif cmd == "mirrors" and len(args) >= 2:
        for image in args[1:]:
            print(image, *(mirrors(args[0], image) or ["(not mirrored: pulled from its source)"]))
    elif cmd == "repo-creds" and len(args) == 3:
        check(args[1])
        print(dump(repo_creds(*args)))
    else:
        sys.exit(__doc__)
