# Common Service Broker (CSB) Alerts Runbook

## Overview
This runbook covers alerts related to Common Service Broker (CSB) performance, resource management, and operational health.

---

## HighBrokerRequestRate

### Meaning
The rate of CSB broker requests has exceeded 50 requests per second for a specific operation.

### Impact
- High broker load
- Potential performance degradation
- Risk of resource exhaustion

### Diagnosis
1. Check request rate:
   ```promql
   sum(rate(ccsb_broker_calls_total[5m])) by (operation) > 50
   ```
2. Identify which operations are high:
   ```bash
   kubectl logs -n <csb-namespace> <csb-pod> | grep -i "operation"
   ```
3. Check broker pod resource usage:
   ```bash
   kubectl top pods -n <csb-namespace>
   ```
4. Review recent service provisioning activity

### Mitigation
1. Verify if load is expected (e.g., bulk provisioning)
2. Scale broker pods if needed:
   ```bash
   kubectl scale deployment -n <csb-namespace> <csb-deployment> --replicas=<count>
   ```
3. Implement rate limiting if necessary
4. Review and optimize broker operations
5. Check for retry storms or stuck operations

---

## ExcessiveBrokerResourceUsage

### Meaning
CSB active resources for a specific status have exceeded 100, indicating high resource management load.

### Impact
- Broker performance degradation
- Potential resource management issues
- Risk of broker overload

### Diagnosis
1. Check active resources:
   ```promql
   sum(ccsb_broker_resources_active) by (status) > 100
   ```
2. List service instances:
   ```bash
   kubectl get serviceinstance -A
   kubectl get servicebinding -A
   ```
3. Check resource status distribution:
   ```bash
   kubectl get serviceinstance -A -o json | jq '.items | group_by(.status.conditions[0].type) | map({status: .[0].status.conditions[0].type, count: length})'
   ```
4. Review broker logs for errors

### Mitigation
1. Investigate stuck or failed resources
2. Clean up orphaned resources:
   ```bash
   kubectl delete serviceinstance -n <namespace> <instance-name>
   ```
3. Review and fix failing provisioning operations
4. Scale broker if legitimate load
5. Implement resource quotas if needed

---

## HighCallbackErrorRate

### Meaning
CSB callback error rate (5xx or 9xx responses) has exceeded 5%.

### Impact
- Service provisioning failures
- Binding operation failures
- User-facing errors

### Diagnosis
1. Check callback error rate:
   ```promql
   (sum(increase(ccsb_callback_total{response_code=~"5..|9.."}[5m])) / sum(increase(ccsb_callback_total[5m]))) > 0.05
   ```
2. Review broker logs for callback errors:
   ```bash
   kubectl logs -n <csb-namespace> <csb-pod> | grep -i "callback\|error"
   ```
3. Check target service health
4. Verify network connectivity

### Mitigation
1. Identify failing callbacks and root cause
2. Fix target service issues
3. Verify network policies allow callback traffic
4. Implement retry logic with backoff
5. Check authentication/authorization for callbacks

---

## SlowWorkqueueProcessing

### Meaning
Average workqueue processing time has exceeded 1 second over 15 minutes.

### Impact
- Delayed resource reconciliation
- Slow provisioning operations
- User experience degradation

### Diagnosis
1. Check workqueue processing time:
   ```promql
   (sum(increase(workqueue_work_duration_seconds_sum[15m])) / sum(increase(workqueue_work_duration_seconds_count[15m]))) > 1
   ```
2. Review broker logs for slow operations
3. Check for resource-intensive reconciliation
4. Monitor broker resource usage

### Mitigation
1. Identify slow reconciliation operations
2. Optimize broker code if needed
3. Increase broker resources (CPU/memory)
4. Scale broker horizontally
5. Review and optimize database queries

---

## SlowCallbackProcessing

### Meaning
Average CSB callback processing time has exceeded 1 second.

### Impact
- Delayed service operations
- Slow provisioning/binding
- Potential timeout issues

### Diagnosis
1. Check callback processing time:
   ```promql
   (sum(increase(ccsb_callback_times_seconds_sum[15m])) / sum(increase(ccsb_callback_times_seconds_count[15m]))) > 1
   ```
2. Identify slow callback endpoints
3. Check target service performance
4. Review network latency

### Mitigation
1. Optimize callback handlers
2. Improve target service performance
3. Implement caching where appropriate
4. Add timeout configurations
5. Consider asynchronous processing

---

## HighActiveWorkers

### Meaning
A controller has more than 50 active workers, indicating high concurrent processing load.

### Impact
- High resource consumption
- Potential performance issues
- Risk of resource exhaustion

### Diagnosis
1. Check active workers:
   ```promql
   sum(controller_runtime_active_workers) by (controller) > 50
   ```
2. Review controller logs:
   ```bash
   kubectl logs -n <csb-namespace> <csb-pod> | grep -i "controller\|worker"
   ```
3. Check for stuck reconciliation loops
4. Monitor resource usage

### Mitigation
1. Verify if load is expected
2. Check for reconciliation loops
3. Optimize controller logic
4. Increase worker pool size if appropriate
5. Scale broker pods

---

## UnfinishedWorkIncreasing

### Meaning
Unfinished work in the workqueue has accumulated beyond 60 seconds.

### Impact
- Work backlog building up
- Delayed operations
- Potential service degradation

### Diagnosis
1. Check unfinished work:
   ```promql
   sum(workqueue_unfinished_work_seconds) by (name) > 60
   ```
2. Review workqueue metrics:
   ```bash
   kubectl logs -n <csb-namespace> <csb-pod> | grep -i "workqueue"
   ```
3. Check for stuck items
4. Monitor queue depth

### Mitigation
1. Identify and resolve stuck work items
2. Increase worker concurrency
3. Optimize work processing
4. Scale broker resources
5. Review and fix failing operations

---

## ItemQueueWaitTooLong

### Meaning
Items are waiting in the workqueue for more than 1 second on average before processing.

### Impact
- Delayed reconciliation
- Slow service operations
- User experience degradation

### Diagnosis
1. Check queue wait time:
   ```promql
   (sum(increase(workqueue_queue_duration_seconds_sum[15m])) / sum(increase(workqueue_queue_duration_seconds_count[15m]))) > 1
   ```
2. Review queue depth and processing rate
3. Check broker resource utilization
4. Monitor worker availability

### Mitigation
1. Increase worker pool size
2. Scale broker horizontally
3. Optimize work processing
4. Increase broker resources
5. Review queue priorities

---

## HighReconcileRate

### Meaning
High reconciliation rate (>10/sec) detected for ServiceBroker resources in a namespace.

### Impact
- High broker load
- Potential performance issues
- Informational - may be expected

### Diagnosis
1. Check reconcile rate:
   ```promql
   sum(rate(ccsb_reconcile_calls_total[15m])) by (resource_namespace) > 10
   ```
2. Identify resources being reconciled:
   ```bash
   kubectl get serviceinstance -n <namespace>
   kubectl get servicebinding -n <namespace>
   ```
3. Check for reconciliation loops
4. Review resource status

### Mitigation
1. Verify if rate is expected (e.g., during bulk operations)
2. Check for unnecessary reconciliation triggers
3. Optimize reconciliation logic
4. Implement reconciliation backoff
5. Scale broker if needed

---

## SlowBrokerCallDuration

### Meaning
Broker request processing time has exceeded 1 second on average.

### Impact
- Slow service operations
- Poor user experience
- Potential timeout issues

### Diagnosis
1. Check broker call duration:
   ```promql
   (sum(increase(ccsb_broker_call_time_seconds_sum[15m])) / sum(increase(ccsb_broker_call_time_seconds_count[15m]))) > 1
   ```
2. Identify slow operations:
   ```bash
   kubectl logs -n <csb-namespace> <csb-pod> | grep -i "duration\|slow"
   ```
3. Check backend service performance
4. Review database query performance

### Mitigation
1. Optimize slow broker operations
2. Improve backend service performance
3. Implement caching strategies
4. Add database indexes
5. Scale broker and backend resources

---

## General CSB Troubleshooting

### Check Broker Health
```bash
# Check broker pods
kubectl get pods -n <csb-namespace>

# Check broker logs
kubectl logs -n <csb-namespace> <csb-pod> --tail=100

# Check broker deployment
kubectl describe deployment -n <csb-namespace> <csb-deployment>

# Check broker service
kubectl get svc -n <csb-namespace>
```

### Check Service Instances and Bindings
```bash
# List all service instances
kubectl get serviceinstance -A

# Check instance status
kubectl describe serviceinstance -n <namespace> <instance-name>

# List all service bindings
kubectl get servicebinding -A

# Check binding status
kubectl describe servicebinding -n <namespace> <binding-name>

# Check for failed resources
kubectl get serviceinstance -A -o json | jq '.items[] | select(.status.conditions[0].status=="False") | {name: .metadata.name, namespace: .metadata.namespace, reason: .status.conditions[0].reason}'
```

### Check Broker Configuration
```bash
# Check broker configmap
kubectl get configmap -n <csb-namespace>
kubectl describe configmap -n <csb-namespace> <configmap-name>

# Check broker secrets
kubectl get secrets -n <csb-namespace>

# Check RBAC
kubectl get clusterrole | grep broker
kubectl get clusterrolebinding | grep broker
```

### Performance Monitoring
```bash
# Check resource usage
kubectl top pods -n <csb-namespace>

# Check metrics
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/<csb-namespace>/pods

# Check HPA if configured
kubectl get hpa -n <csb-namespace>
```

### Workqueue Analysis
```bash
# Check workqueue metrics via broker metrics endpoint
kubectl port-forward -n <csb-namespace> <csb-pod> 8080:8080
curl localhost:8080/metrics | grep workqueue
```

### Clean Up Operations
```bash
# Delete stuck service instance
kubectl delete serviceinstance -n <namespace> <instance-name>

# Force delete if stuck
kubectl patch serviceinstance -n <namespace> <instance-name> -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete serviceinstance -n <namespace> <instance-name>

# Delete stuck service binding
kubectl delete servicebinding -n <namespace> <binding-name>
```

### Broker Restart
```bash
# Restart broker pods
kubectl rollout restart deployment -n <csb-namespace> <csb-deployment>

# Check rollout status
kubectl rollout status deployment -n <csb-namespace> <csb-deployment>
```

---

## Additional Resources
- Service Broker Documentation: Review internal CSB documentation
- Kubernetes Service Catalog: https://kubernetes.io/docs/concepts/extend-kubernetes/service-catalog/
- Open Service Broker API: https://www.openservicebrokerapi.org/
- Monitoring Dashboard: Review CSB Grafana dashboards
- Controller Runtime: https://github.com/kubernetes-sigs/controller-runtime