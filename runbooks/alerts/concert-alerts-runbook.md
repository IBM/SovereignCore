# Concert Service Alerts Runbook

## Overview
This runbook covers alerts related to Concert service availability, performance, and error rates.

---

## ConcertBackendDown

### Meaning
The HAProxy backend for Concert service route is reporting as down (backend_up = 0).

### Impact
- Concert service unavailable
- Users cannot access Concert functionality
- Critical service disruption

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="concert"}) by (route) == 0
   ```
2. Verify pod status in concert namespace:
   ```bash
   kubectl get pods -n concert
   ```
3. Check pod logs for errors:
   ```bash
   kubectl logs -n concert <pod-name> --tail=100
   ```
4. Verify service endpoints:
   ```bash
   kubectl get endpoints -n concert
   kubectl describe service -n concert <service-name>
   ```
5. Check pod events:
   ```bash
   kubectl describe pod -n concert <pod-name>
   ```

### Mitigation
1. Restart failed pods if necessary:
   ```bash
   kubectl delete pod -n concert <pod-name>
   ```
2. Check for resource constraints (CPU/memory):
   ```bash
   kubectl top pods -n concert
   kubectl describe pod -n concert <pod-name> | grep -A 5 Limits
   ```
3. Review recent deployments or configuration changes
4. Verify network connectivity and policies
5. Check application health endpoints
6. Escalate to development team if application issue

---

## ConcertWorkflowsBackendDown

### Meaning
The HAProxy backend for Concert Workflows service is down.

### Impact
- Concert Workflows service unavailable
- Workflow execution disrupted
- Critical business process failures

### Diagnosis
1. Check backend status:
   ```promql
   min(haproxy_backend_up{exported_namespace="concert-workflows"}) by (route) == 0
   ```
2. Verify pod status:
   ```bash
   kubectl get pods -n concert-workflows
   ```
3. Check pod logs:
   ```bash
   kubectl logs -n concert-workflows <pod-name> --tail=100
   ```
4. Verify service configuration:
   ```bash
   kubectl get service -n concert-workflows
   kubectl describe service -n concert-workflows <service-name>
   ```
5. Check for dependent service availability

### Mitigation
1. Restart unhealthy pods
2. Verify workflow engine configuration
3. Check database connectivity
4. Review resource utilization
5. Verify message queue connectivity if applicable
6. Rollback recent changes if necessary

---

## ConcertHighLatency

### Meaning
Concert service average response latency has exceeded 500ms for 5 minutes.

### Impact
- Poor user experience
- Potential timeout issues
- Reduced throughput
- User complaints

### Diagnosis
1. Check latency metrics:
   ```promql
   sum(haproxy_backend_http_average_response_latency_milliseconds{exported_namespace=~"concert|concert-workflow"}) by (route) > 500
   ```
2. Identify slow endpoints:
   ```bash
   kubectl logs -n concert <pod-name> | grep -i "slow\|timeout"
   ```
3. Review application performance metrics
4. Check database query performance
5. Verify external service dependencies
6. Check resource utilization:
   ```bash
   kubectl top pods -n concert
   kubectl top nodes
   ```

### Mitigation
1. Identify and optimize slow endpoints
2. Review and optimize database queries
3. Implement caching strategies
4. Scale application resources:
   ```bash
   kubectl scale deployment -n concert <deployment-name> --replicas=<count>
   ```
5. Check for resource constraints and increase limits if needed
6. Review and optimize code paths
7. Add database indexes if needed
8. Implement request timeouts

---

## ConcertHighLatencyCritical

### Meaning
Concert service average response latency has exceeded 1 second for 5 minutes - critical threshold.

### Impact
- Severe user experience degradation
- High probability of timeouts
- Service effectively unusable
- Urgent intervention required

### Diagnosis
1. Check critical latency:
   ```promql
   sum(haproxy_backend_http_average_response_latency_milliseconds{exported_namespace=~"concert|concert-workflow"}) by (route) > 1000
   ```
2. Identify root cause immediately:
   - Check for resource exhaustion
   - Review recent deployments
   - Check database performance
   - Verify external dependencies
3. Check for cascading failures
4. Review application logs for errors

### Mitigation
1. **Immediate actions:**
   - Scale up application immediately if resource-constrained
   - Restart pods if memory leaks suspected
   - Enable circuit breakers for failing dependencies
2. **Short-term fixes:**
   - Rollback recent deployments if applicable
   - Increase resource limits
   - Optimize critical paths
3. **Follow-up:**
   - Conduct root cause analysis
   - Implement performance improvements
   - Add monitoring and alerting

---

## ConcertHighErrorRate

### Meaning
Concert service 5xx error rate has exceeded 5% for 2 minutes.

### Impact
- Service reliability degraded
- User operations failing
- Potential data integrity issues
- User experience impacted

### Diagnosis
1. Check error rate:
   ```promql
   sum(irate(haproxy_backend_http_responses_total{exported_namespace="concert",code="5xx"}[5m])) / sum(irate(haproxy_backend_http_responses_total{exported_namespace="concert"}[5m])) > 0.05
   ```
2. Review application logs for error patterns:
   ```bash
   kubectl logs -n concert <pod-name> | grep -i "error\|exception\|failed"
   ```
3. Check specific error codes and messages
4. Verify database connectivity:
   ```bash
   kubectl exec -n concert <pod-name> -- nc -zv <db-host> <db-port>
   ```
5. Check external service dependencies
6. Review recent code deployments

### Mitigation
1. Identify and fix root cause of errors
2. Rollback recent deployments if errors started after deployment
3. Restore database connectivity if needed
4. Implement circuit breakers for failing dependencies
5. Add retry logic with exponential backoff
6. Scale resources if needed
7. Fix application bugs causing errors

---

## ConcertHighErrorRateCritical

### Meaning
Concert service 5xx error rate has exceeded 10% - critical threshold.

### Impact
- Severe service degradation
- Majority of operations failing
- Critical business impact
- Immediate intervention required

### Diagnosis
1. Check critical error rate:
   ```promql
   sum(irate(haproxy_backend_http_responses_total{exported_namespace="concert",code="5xx"}[5m])) / sum(irate(haproxy_backend_http_responses_total{exported_namespace="concert"}[5m])) > 0.10
   ```
2. **Immediate investigation:**
   - Check if service is completely down
   - Review recent changes
   - Check infrastructure health
   - Verify all dependencies

### Mitigation
1. **Immediate actions:**
   - Consider rolling back to last known good version
   - Restart all pods if necessary
   - Enable maintenance mode if available
   - Notify stakeholders
2. **Troubleshooting:**
   - Fix critical bugs immediately
   - Restore failed dependencies
   - Scale resources if infrastructure issue
3. **Communication:**
   - Update status page
   - Notify affected users
   - Escalate to senior engineers

---

## General Concert Service Troubleshooting

### Check Service Health
```bash
# Check all Concert resources
kubectl get all -n concert
kubectl get all -n concert-workflows

# Check pod status and restarts
kubectl get pods -n concert -o wide
kubectl get pods -n concert --field-selector=status.phase!=Running

# Check pod logs
kubectl logs -n concert <pod-name> --tail=100 --follow

# Check previous pod logs if restarted
kubectl logs -n concert <pod-name> --previous

# Check pod events
kubectl get events -n concert --sort-by='.lastTimestamp'
```

### Performance Analysis
```bash
# Check resource usage
kubectl top pods -n concert
kubectl top nodes

# Check resource limits and requests
kubectl describe pod -n concert <pod-name> | grep -A 10 "Limits\|Requests"

# Check HPA status if configured
kubectl get hpa -n concert
kubectl describe hpa -n concert <hpa-name>
```

### Network Troubleshooting
```bash
# Check services
kubectl get svc -n concert
kubectl describe svc -n concert <service-name>

# Check endpoints
kubectl get endpoints -n concert

# Check network policies
kubectl get networkpolicy -n concert
kubectl describe networkpolicy -n concert <policy-name>

# Test connectivity from pod
kubectl exec -n concert <pod-name> -- curl -v http://<service-name>:<port>/health
```

### Database Connectivity
```bash
# Test database connection
kubectl exec -n concert <pod-name> -- nc -zv <db-host> <db-port>

# Check database credentials secret
kubectl get secret -n concert <db-secret-name> -o yaml

# Check database logs
kubectl logs -n <db-namespace> <db-pod-name>
```

### HAProxy Metrics
```bash
# Check HAProxy stats
kubectl exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats

# Check specific backend
kubectl exec -n <haproxy-namespace> <haproxy-pod> -- curl localhost:1936/stats | grep concert
```

### Scaling Operations
```bash
# Manual scaling
kubectl scale deployment -n concert <deployment-name> --replicas=<count>

# Check deployment status
kubectl rollout status deployment -n concert <deployment-name>

# Check deployment history
kubectl rollout history deployment -n concert <deployment-name>

# Rollback deployment
kubectl rollout undo deployment -n concert <deployment-name>
```

---

## Additional Resources
- Concert Service Documentation: Review internal documentation
- HAProxy Dashboard: Check HAProxy metrics in Grafana
- Application Logs: Review centralized logging system
- APM Tools: Check application performance monitoring dashboards
- Database Monitoring: Review database performance metrics
- Service Dependencies: Verify all dependent services are healthy