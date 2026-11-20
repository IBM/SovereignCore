# Deploy profiles

| Target | Values |
|---|---|
| Hub | `hub/values-global.yaml` + `hub/values-baremetal.yaml` |
| CPU tenant | `spoke/values-global-spoke.yaml` + `spoke/values-baremetal-spoke.yaml` |
| GPU tenant | Replace the CPU profile with `spoke/values-baremetal-spoke-gpu.yaml` |

From `runbooks/configurations/intel-tdx` with [site configuration](env/README.md):

```bash
VALUES_CG=deploy/spoke/values-baremetal-spoke-gpu.yaml APPLY=true ./scripts/deploy-coco-spoke.sh
```

Paths resolve against `runbooks/configurations/intel-tdx`. Deployments use OCI charts from hub Quay.
The build/publisher includes pinned upstream samples. `deploy/versions.yaml` is the
central pin list, checked against chart metadata/profiles; hub/tenant initdata must match.
See the `scripts/build-upstream.sh` header for build/overlay rules.
