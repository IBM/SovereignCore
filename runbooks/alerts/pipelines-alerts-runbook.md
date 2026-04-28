# Tekton Pipelines Alerts Runbook

## Overview
This runbook covers alerts related to Tekton Pipelines availability, performance, and operational health.

---

## HighActivePipelines

### Meaning
More than 50 active pipelines are currently running simultaneously.

### Impact
- High cluster resource consumption
- Potential resource exhaustion
- Risk of pipeline queue buildup
- Performance degradation

### Diagnosis
1. Check active pipeline count:
   ```promql
   count by (pipeline) (tekton_pipelines_controller_pipelinerun_duration_seconds_sum{}) > 50
   ```

2. List all running PipelineRuns:
   ```bash
   # Check running PipelineRuns
   kubectl get pipelinerun -A --field-selector=status.conditions[0].status=Unknown
   
   # Count by namespace
   kubectl get pipelinerun -A --field-selector=status.conditions[0].status=Unknown -o json | \
     jq -r '.items[] | .metadata.namespace' | sort | uniq -c
   ```

3. Check cluster resource usage:
   ```bash
   # Check node resources
   kubectl top nodes
   
   # Check pod resources
   kubectl top pods -A | grep pipeline
   ```

4. Review pipeline controller status:
   ```bash
   kubectl get pods -n openshift-pipelines
   kubectl logs -n openshift-pipelines <tekton-pipelines-controller-pod>
   ```

### Mitigation
1. Verify if high pipeline count is expected (e.g., CI/CD burst)
2. Check for stuck or long-running pipelines:
   ```bash
   kubectl get pipelinerun -A -o json | \
     jq -r '.items[] | select(.status.conditions[0].status=="Unknown") | 
     "\(.metadata.namespace)/\(.metadata.name) - Started: \(.status.startTime)"'
   ```
3. Cancel stuck pipelines if necessary:
   ```bash
   kubectl patch pipelinerun -n <namespace> <pipelinerun-name> \
     -p '{"spec":{"status":"PipelineRunCancelled"}}' --type=merge
   ```
4. Scale Tekton controller if needed
5. Implement pipeline concurrency limits
6. Review and optimize pipeline resource requests

---

## RecentPipelineFailures

### Meaning
Pipeline runs have failed pods for more than 10 minutes.

### Impact
- CI/CD process disrupted
- Build/deployment failures
- Development workflow blocked

### Diagnosis
1. Check failed pipeline runs:
   ```promql
   sum by (label_tekton_dev_pipeline, label_tekton_dev_pipeline_run) (
     kube_pod_status_phase{phase="Failed"}
     and on(pod)
     kube_pod_labels{label_tekton_dev_pipeline_run!=""}
   ) > 0
   ```

2. List failed PipelineRuns:
   ```bash
   # Get failed PipelineRuns
   kubectl get pipelinerun -A --field-selector=status.conditions[0].status=False
   
   # Get detailed status
   kubectl get pipelinerun -A -o json | \
     jq -r '.items[] | select(.status.conditions[0].status=="False") | 
     "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[0].message)"'
   ```

3. Check failed TaskRuns:
   ```bash
   # List failed TaskRuns
   kubectl get taskrun -A --field-selector=status.conditions[0].status=False
   
   # Get failure details
   kubectl describe taskrun -n <namespace> <taskrun-name>
   ```

4. Review pod logs:
   ```bash
   # Get pods from failed PipelineRun
   kubectl get pods -n <namespace> -l tekton.dev/pipelineRun=<pipelinerun-name>
   
   # Check logs
   kubectl logs -n <namespace> <pod-name> --all-containers
   ```

### Mitigation
1. Identify failure cause from logs and events
2. Common failure causes:
   - **Image pull errors**: Fix image registry or credentials
   - **Resource limits**: Increase CPU/memory limits
   - **Timeout**: Increase task timeout
   - **Script errors**: Fix pipeline/task scripts
   - **Missing resources**: Create required ConfigMaps/Secrets

3. Fix the underlying issue and retry:
   ```bash
   # Delete failed PipelineRun to retry
   kubectl delete pipelinerun -n <namespace> <pipelinerun-name>
   
   # Or create new PipelineRun
   tkn pipeline start <pipeline-name> -n <namespace>
   ```

4. Update pipeline definition if needed:
   ```bash
   kubectl apply -f pipeline.yaml
   ```

---

## PendingPipelineRun

### Meaning
More than 5 PipelineRuns are pending (no running pods) for more than 10 minutes.

### Impact
- Pipeline execution delayed
- CI/CD bottleneck
- Resource scheduling issues

### Diagnosis
1. Check pending PipelineRuns:
   ```promql
   sum by (label_tekton_dev_pipeline, label_tekton_dev_pipeline_run) (
     kube_pod_status_phase{phase="Pending"}
     and on(pod)
     kube_pod_labels{label_tekton_dev_pipeline_run!=""}
   ) > 5
   ```

2. List pending PipelineRuns:
   ```bash
   # Get pending pods
   kubectl get pods -A -l tekton.dev/pipelineRun --field-selector=status.phase=Pending
   
   # Get detailed status
   kubectl describe pod -n <namespace> <pod-name>
   ```

3. Check for resource constraints:
   ```bash
   # Check node resources
   kubectl top nodes
   kubectl describe nodes | grep -A 5 "Allocated resources"
   
   # Check pending pod events
   kubectl get events -n <namespace> --field-selector involvedObject.name=<pod-name>
   ```

4. Check for scheduling issues:
   ```bash
   # Check pod scheduling conditions
   kubectl get pods -n <namespace> <pod-name> -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")]}'
   ```

### Mitigation
1. **Insufficient resources:**
   - Add more nodes to cluster
   - Scale down non-critical workloads
   - Reduce pipeline resource requests

2. **Node selector/affinity issues:**
   - Review and fix node selectors
   - Update pipeline workspace configuration

3. **PVC binding issues:**
   - Check PVC status:
     ```bash
     kubectl get pvc -n <namespace>
     ```
   - Provision storage if needed

4. **Image pull issues:**
   - Verify image registry accessibility
   - Check image pull secrets

5. **Quota exceeded:**
   - Check resource quotas:
     ```bash
     kubectl get resourcequota -n <namespace>
     kubectl describe resourcequota -n <namespace>
     ```
   - Increase quota or clean up resources

---

## PipelinerunIncreaseSpike5m

### Meaning
More than 20 PipelineRuns have been created in the last 5 minutes for a specific pipeline.

### Impact
- Sudden load on cluster
- Potential resource exhaustion
- May indicate automation issue

### Diagnosis
1. Check PipelineRun creation rate:
   ```promql
   sum(increase(tekton_pipelines_controller_pipelinerun_duration_seconds_count[5m])) by (pipeline) > 20
   ```

2. List recent PipelineRuns:
   ```bash
   # Get recent PipelineRuns
   kubectl get pipelinerun -A --sort-by=.metadata.creationTimestamp | tail -30
   
   # Count by pipeline
   kubectl get pipelinerun -A -o json | \
     jq -r '.items[] | select(.metadata.creationTimestamp > (now - 300 | todate)) | 
     .metadata.labels["tekton.dev/pipeline"]' | sort | uniq -c
   ```

3. Check trigger sources:
   ```bash
   # Check EventListeners
   kubectl get eventlistener -A
   
   # Check TriggerBindings
   kubectl get triggerbinding -A
   
   # Check webhook events
   kubectl logs -n <namespace> <eventlistener-pod>
   ```

4. Review automation/CI system:
   - Check for webhook storms
   - Review CI/CD configuration
   - Check for retry loops

### Mitigation
1. **If legitimate load:**
   - Verify cluster can handle load
   - Scale resources if needed
   - Monitor completion rate

2. **If automation issue:**
   - Pause webhook/trigger temporarily
   - Fix automation configuration
   - Implement rate limiting

3. **If malicious:**
   - Block webhook source
   - Review security policies
   - Contact security team

4. **Cleanup if needed:**
   ```bash
   # Delete old completed PipelineRuns
   kubectl delete pipelinerun -n <namespace> --field-selector=status.conditions[0].status=True
   ```

---

## HighRunningPipelineRuns

### Meaning
More than 30 PipelineRuns are currently running.

### Impact
- High resource consumption
- Potential cluster overload
- Performance degradation

### Diagnosis
1. Check running PipelineRuns count:
   ```promql
   max(tekton_pipelines_controller_running_pipelineruns) > 30
   ```

2. List running PipelineRuns:
   ```bash
   kubectl get pipelinerun -A --field-selector=status.conditions[0].status=Unknown
   ```

3. Check resource usage:
   ```bash
   kubectl top nodes
   kubectl top pods -A | grep pipeline
   ```

### Mitigation
1. Verify if load is expected
2. Implement concurrency limits in pipelines
3. Scale cluster resources if needed
4. Cancel non-critical pipelines if necessary
5. Review pipeline scheduling strategy

---

## HighRunningTaskRuns

### Meaning
More than 80 TaskRuns are currently running.

### Impact
- Very high resource consumption
- Risk of cluster instability
- Performance issues

### Diagnosis
1. Check running TaskRuns count:
   ```promql
   max(tekton_pipelines_controller_running_taskruns) > 80
   ```

2. List running TaskRuns:
   ```bash
   kubectl get taskrun -A --field-selector=status.conditions[0].status=Unknown
   ```

3. Check which pipelines are consuming most tasks:
   ```bash
   kubectl get taskrun -A -o json | \
     jq -r '.items[] | select(.status.conditions[0].status=="Unknown") | 
     .metadata.labels["tekton.dev/pipeline"]' | sort | uniq -c | sort -rn
   ```

### Mitigation
1. Review pipeline parallelism settings
2. Reduce concurrent task execution
3. Scale cluster if legitimate load
4. Optimize task resource requests
5. Implement task queuing strategy

---

## General Tekton Troubleshooting

### Check Tekton Installation
```bash
# Check Tekton operator
kubectl get pods -n openshift-operators | grep tekton

# Check Tekton pipelines
kubectl get pods -n openshift-pipelines

# Check Tekton version
tkn version
```

### Monitor Pipeline Execution
```bash
# Watch PipelineRun
tkn pipelinerun logs -n <namespace> <pipelinerun-name> -f

# List PipelineRuns
tkn pipelinerun list -n <namespace>

# Describe PipelineRun
tkn pipelinerun describe -n <namespace> <pipelinerun-name>

# Get PipelineRun YAML
kubectl get pipelinerun -n <namespace> <pipelinerun-name> -o yaml
```

### Debug Failed Pipelines
```bash
# Get failure reason
kubectl get pipelinerun -n <namespace> <pipelinerun-name> \
  -o jsonpath='{.status.conditions[0].message}'

# Check TaskRun status
kubectl get taskrun -n <namespace> -l tekton.dev/pipelineRun=<pipelinerun-name>

# Get pod logs
kubectl logs -n <namespace> <pod-name> --all-containers

# Debug with step logs
tkn pipelinerun logs -n <namespace> <pipelinerun-name> --all
```

### Clean Up Resources
```bash
# Delete completed PipelineRuns older than 1 hour
kubectl get pipelinerun -A -o json | \
  jq -r '.items[] | select(.status.completionTime != null and 
  (.status.completionTime | fromdateiso8601) < (now - 3600)) | 
  "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns name; do kubectl delete pipelinerun -n $ns $name; done

# Delete failed PipelineRuns
kubectl delete pipelinerun -A --field-selector=status.conditions[0].status=False

# Clean up old TaskRuns
kubectl delete taskrun -A --field-selector=status.conditions[0].status=True
```

### Performance Tuning
```bash
# Check Tekton controller configuration
kubectl get configmap -n openshift-pipelines config-defaults -o yaml

# Adjust concurrency settings
kubectl edit configmap -n openshift-pipelines config-defaults

# Scale Tekton controller
kubectl scale deployment -n openshift-pipelines tekton-pipelines-controller --replicas=2
```

---

## Additional Resources
- Tekton Documentation: https://tekton.dev/docs/
- OpenShift Pipelines: https://docs.openshift.com/container-platform/latest/cicd/pipelines/understanding-openshift-pipelines.html
- Tekton CLI (tkn): https://github.com/tektoncd/cli
- Pipeline Dashboard: Review Tekton dashboard in OpenShift Console
- Metrics: Monitor tekton_pipelines_controller_* metrics in Prometheus