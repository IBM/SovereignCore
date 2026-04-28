# Log Spike Alerts Runbook

## Overview
This runbook covers alerts related to sudden spikes in pod log volume, which may indicate application issues, errors, or abnormal behavior.

---

## PodLogVolumeSuddenSpike

### Meaning
A pod is producing logs at a significantly higher rate than its normal baseline (more than 3 standard deviations above the 1-hour average), and the baseline rate is above 100KB/sec.

### Impact
- Potential application issue or error loop
- Increased storage consumption
- Performance degradation
- Possible disk space exhaustion
- Increased logging infrastructure load

### Diagnosis

1. Check log volume spike:
   ```promql
   sum by (namespace, pod) (
     (rate(log_logged_bytes_total[5m]))
     and
     (rate(log_logged_bytes_total[5m]) > avg_over_time(rate(log_logged_bytes_total[5m])[1h:]) + 3 * stddev_over_time(rate(log_logged_bytes_total[5m])[1h:]))
     and
     (avg_over_time(rate(log_logged_bytes_total[5m])[1h:]) > 100000)
   )
   ```

2. Identify the affected pod:
   ```bash
   # Check pod status
   kubectl get pod -n <namespace> <pod-name>
   
   # Check pod events
   kubectl describe pod -n <namespace> <pod-name>
   ```

3. Review recent logs to identify the issue:
   ```bash
   # View recent logs
   kubectl logs -n <namespace> <pod-name> --tail=100
   
   # Follow logs in real-time
   kubectl logs -n <namespace> <pod-name> --follow
   
   # Check for error patterns
   kubectl logs -n <namespace> <pod-name> --tail=1000 | grep -i "error\|exception\|failed\|warning"
   ```

4. Analyze log patterns:
   ```bash
   # Count log entries by pattern
   kubectl logs -n <namespace> <pod-name> --tail=10000 | awk '{print $1, $2, $3}' | sort | uniq -c | sort -rn | head -20
   
   # Check for repeated messages
   kubectl logs -n <namespace> <pod-name> --tail=10000 | sort | uniq -c | sort -rn | head -20
   ```

5. Check application health:
   ```bash
   # Check resource usage
   kubectl top pod -n <namespace> <pod-name>
   
   # Check application metrics
   kubectl exec -n <namespace> <pod-name> -- curl localhost:<metrics-port>/metrics
   ```

### Common Causes and Mitigation

#### 1. Error Loop / Exception Storm

**Symptoms:**
- Repeated error messages
- Stack traces flooding logs
- Application not functioning properly

**Diagnosis:**
```bash
# Check for repeated errors
kubectl logs -n <namespace> <pod-name> --tail=1000 | grep -i "error\|exception" | sort | uniq -c | sort -rn

# Check error rate over time
kubectl logs -n <namespace> <pod-name> --since=1h | grep -c "ERROR"
```

**Mitigation:**
1. Identify the root cause of errors
2. Fix the underlying issue (database connectivity, missing config, etc.)
3. Restart the pod if necessary:
   ```bash
   kubectl delete pod -n <namespace> <pod-name>
   ```
4. Implement error rate limiting in application
5. Add circuit breakers for failing dependencies

#### 2. Debug/Verbose Logging Enabled

**Symptoms:**
- Excessive debug messages
- Detailed trace logs
- Performance impact

**Diagnosis:**
```bash
# Check log level
kubectl logs -n <namespace> <pod-name> --tail=100 | grep -i "debug\|trace"

# Check application configuration
kubectl get configmap -n <namespace>
kubectl describe configmap -n <namespace> <configmap-name>
```

**Mitigation:**
1. Update log level configuration:
   ```bash
   # Edit configmap
   kubectl edit configmap -n <namespace> <configmap-name>
   
   # Or patch it
   kubectl patch configmap -n <namespace> <configmap-name> -p '{"data":{"LOG_LEVEL":"INFO"}}'
   ```
2. Restart pods to apply new configuration:
   ```bash
   kubectl rollout restart deployment -n <namespace> <deployment-name>
   ```
3. Verify log level change took effect

#### 3. Infinite Loop / Retry Storm

**Symptoms:**
- Same operation repeated continuously
- Retry messages flooding logs
- High CPU usage

**Diagnosis:**
```bash
# Check for retry patterns
kubectl logs -n <namespace> <pod-name> --tail=1000 | grep -i "retry\|attempt"

# Check CPU usage
kubectl top pod -n <namespace> <pod-name>

# Check for infinite loops in code
kubectl logs -n <namespace> <pod-name> --tail=1000 | awk '{print $NF}' | sort | uniq -c | sort -rn
```

**Mitigation:**
1. Identify the failing operation
2. Fix the root cause (e.g., unreachable service, invalid configuration)
3. Implement exponential backoff for retries
4. Add maximum retry limits
5. Implement circuit breakers
6. Restart pod if stuck:
   ```bash
   kubectl delete pod -n <namespace> <pod-name>
   ```

#### 4. High Traffic / Load

**Symptoms:**
- Increased request logging
- Normal log messages but high volume
- Corresponds to traffic spike

**Diagnosis:**
```bash
# Check request rate in logs
kubectl logs -n <namespace> <pod-name> --tail=1000 | grep -i "request\|http" | wc -l

# Check application metrics
kubectl exec -n <namespace> <pod-name> -- curl localhost:<metrics-port>/metrics | grep http_requests

# Check pod resource usage
kubectl top pod -n <namespace> <pod-name>
```

**Mitigation:**
1. Verify if traffic increase is legitimate
2. Scale application if needed:
   ```bash
   kubectl scale deployment -n <namespace> <deployment-name> --replicas=<count>
   ```
3. Implement request sampling for logs
4. Use structured logging with appropriate levels
5. Consider log aggregation and sampling

#### 5. Memory Leak / Resource Exhaustion

**Symptoms:**
- Increasing log volume over time
- Out of memory errors
- Pod restarts

**Diagnosis:**
```bash
# Check memory usage
kubectl top pod -n <namespace> <pod-name>

# Check for OOM kills
kubectl describe pod -n <namespace> <pod-name> | grep -A 5 "Last State"

# Check restart count
kubectl get pod -n <namespace> <pod-name> -o jsonpath='{.status.containerStatuses[0].restartCount}'
```

**Mitigation:**
1. Investigate memory leak in application
2. Increase memory limits if appropriate:
   ```bash
   kubectl set resources deployment -n <namespace> <deployment-name> --limits=memory=2Gi
   ```
3. Implement proper resource cleanup
4. Add memory profiling
5. Consider restarting pod as temporary fix

---

## Log Management Best Practices

### Configure Log Levels
```yaml
# Example ConfigMap for log configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-logging-config
  namespace: <namespace>
data:
  LOG_LEVEL: "INFO"
  LOG_FORMAT: "json"
  LOG_SAMPLING_RATE: "0.1"  # Sample 10% of logs at high volume
```

### Implement Log Rotation
```yaml
# Example pod with log rotation
apiVersion: v1
kind: Pod
metadata:
  name: app-with-log-rotation
spec:
  containers:
  - name: app
    image: app:latest
    volumeMounts:
    - name: logs
      mountPath: /var/log/app
  - name: log-rotator
    image: busybox
    command: ["/bin/sh", "-c"]
    args:
    - |
      while true; do
        find /var/log/app -name "*.log" -size +100M -exec truncate -s 0 {} \;
        sleep 300
      done
    volumeMounts:
    - name: logs
      mountPath: /var/log/app
  volumes:
  - name: logs
    emptyDir: {}
```

### Monitor Log Volume
```bash
# Check log volume by namespace
kubectl get pods -A -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns pod; do
  size=$(kubectl exec -n $ns $pod -- du -sh /var/log 2>/dev/null | awk '{print $1}')
  echo "$ns/$pod: $size"
done | sort -k2 -h
```

### Set Up Log Alerts
```yaml
# Example PrometheusRule for log monitoring
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: log-volume-alerts
spec:
  groups:
  - name: log-alerts
    rules:
    - alert: HighLogVolume
      expr: rate(log_logged_bytes_total[5m]) > 1000000
      for: 5m
      annotations:
        summary: "High log volume detected"
```

---

## Troubleshooting Commands

### Check Logging Infrastructure
```bash
# Check logging operator/stack
kubectl get pods -n openshift-logging

# Check log forwarder configuration
kubectl get clusterlogforwarder -n openshift-logging

# Check log storage
kubectl get pvc -n openshift-logging
```

### Analyze Log Patterns
```bash
# Get log statistics
kubectl logs -n <namespace> <pod-name> --tail=10000 | \
  awk '{print $1}' | sort | uniq -c | sort -rn

# Find most common log messages
kubectl logs -n <namespace> <pod-name> --tail=10000 | \
  cut -d' ' -f4- | sort | uniq -c | sort -rn | head -20

# Check log timestamps for gaps
kubectl logs -n <namespace> <pod-name> --timestamps --tail=1000 | \
  awk '{print $1}' | sort | uniq -c
```

### Export Logs for Analysis
```bash
# Export logs to file
kubectl logs -n <namespace> <pod-name> --since=1h > pod-logs.txt

# Export all container logs from pod
for container in $(kubectl get pod -n <namespace> <pod-name> -o jsonpath='{.spec.containers[*].name}'); do
  kubectl logs -n <namespace> <pod-name> -c $container > ${pod-name}-${container}.log
done

# Compress logs
tar -czf pod-logs-$(date +%Y%m%d-%H%M%S).tar.gz *.log
```

---

## Additional Resources
- OpenShift Logging: https://docs.openshift.com/container-platform/latest/logging/cluster-logging.html
- Kubernetes Logging: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Log Aggregation Dashboard: Review centralized logging system
- Application Logging Best Practices: Review internal documentation
- Prometheus Metrics: Monitor log_logged_bytes_total metric