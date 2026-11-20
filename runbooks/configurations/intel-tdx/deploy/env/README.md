# Site configuration

Keep site values in `deploy/env/<site>/site.env`. From `runbooks/configurations/intel-tdx` in Bash:

```bash
cp -r deploy/env/example deploy/env/mysite
# Edit site.env before using the site.
SITE=mysite ./scripts/deploy-coco-hub.sh       # print manifests
```

`SITE` or `SITE_ENV=/path/to/site.env` is required by site-aware scripts; there is no
implicit site fallback. The commented example defines every key. Exported values
override its defaults. Deploy scripts pass site values as root Application parameters.

| Required value | Meaning |
|---|---|
| `CHART_REGISTRY`, `OCI_ORG` | Site OCI chart registry and organization/path. |
| `MIRROR_REGISTRY`, `MIRROR_HOME` | Image registry and bastion mirror workspace/tools. |
| `HUB_DOMAIN` | Hub base domain; the KBS route derives from it. |
| `HUB_KUBECONFIG`, `TENANT_KUBECONFIG` | Explicit cluster credentials; protect these files. |
| `EXPECT_HUB_API_SERVER`, `EXPECT_TENANT_API_SERVER` | Exact kubeconfig `server:` URLs for guarded scripts (trailing slash ignored). |
| `TENANT_CLUSTER` | Hub ManagedCluster name for this tenant. |
| `TENANT_AGENT_NAMESPACE` | CUGA agent namespace; when set, the tenant deploy adds the agent's TDX rules and `cuga-jwt-leeway` (`deploy/spoke/values-cuga-agent.yaml`). Sovereign Core creates the agent itself. Empty: no agent integration. |
| `HUB_INGRESS_CA_FILE`, `MIRROR_CA_FILE` | Trusted PEM CA bundles from an authenticated source. |
| `TDX_REGISTRY_AUTH_FILE` | Mode-0600 dockerconfigjson with dedicated read-only robots. |

Do not derive trust from an unauthenticated TLS connection. Use each script's header
for overrides and TLS exceptions; defaults and effects are specific to the helper.
The upstream firmware collector and CA-embedding helper require explicit `KUBECONFIG`;
not every helper calls the cluster guard.

Tenant namespaces must be valid Kubernetes names. Set `TENANT_AGENT_NAMESPACE` before
deploying a tenant that has a CUGA agent; to add an agent later, set it and deploy again; wait for both initdata ConfigMaps before creating confidential pods. Generated
long policy names include a hash suffix to distinguish namespaces with a shared prefix.
