# HashiCorp Vault Alerts Runbook

## Overview
This runbook covers alerts related to HashiCorp Vault security, availability, and performance monitoring.

---

## VaultSealed

### Meaning
Vault instance is sealed and cannot process any requests. A sealed Vault means the encryption keys are not available in memory, and Vault cannot decrypt data.

### Impact
- **Critical service disruption**
- All Vault operations unavailable
- Applications cannot access secrets
- Authentication and authorization blocked
- Complete loss of secret management functionality

### Diagnosis
1. Check Vault seal status:
   ```promql
   vault_core_unsealed == 0
   ```

2. Verify Vault pod status:
   ```bash
   kubectl get pods -n vault
   kubectl describe pod -n vault <vault-pod>
   ```

3. Check Vault seal status via CLI:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault status
   ```

4. Check Vault logs for seal reason:
   ```bash
   kubectl logs -n vault <vault-pod> | grep -i "seal\|unseal"
   ```

5. Check for recent pod restarts:
   ```bash
   kubectl get pods -n vault -o wide
   ```

### Mitigation

#### Automatic Unsealing (if configured):
1. Verify auto-unseal configuration:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault operator init -status
   ```

2. Check auto-unseal service (e.g., AWS KMS, Azure Key Vault):
   ```bash
   # Check if auto-unseal service is accessible
   kubectl logs -n vault <vault-pod> | grep -i "auto-unseal"
   ```

3. Restart Vault pod if auto-unseal is configured:
   ```bash
   kubectl delete pod -n vault <vault-pod>
   ```

#### Manual Unsealing:
1. **Gather unseal keys** (from secure storage - requires multiple key holders)

2. **Unseal Vault** (requires threshold number of keys, typically 3 out of 5):
   ```bash
   # Unseal with first key
   kubectl exec -n vault <vault-pod> -- vault operator unseal <key1>
   
   # Unseal with second key
   kubectl exec -n vault <vault-pod> -- vault operator unseal <key2>
   
   # Unseal with third key
   kubectl exec -n vault <vault-pod> -- vault operator unseal <key3>
   ```

3. **Verify unseal status**:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault status
   ```

4. **Check Vault is operational**:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault status | grep "Sealed"
   # Should show: Sealed: false
   ```

#### If Vault Sealed Due to Issue:
1. Check for storage backend issues
2. Verify network connectivity
3. Check for resource constraints
4. Review Vault audit logs
5. Contact security team if suspicious activity

---

## VaultTooManyInfinityTokens

### Meaning
More than 3 tokens with infinite TTL (Time To Live) exist in Vault. Infinity tokens never expire and pose a security risk.

### Impact
- Security risk - tokens never expire
- Potential for credential abuse
- Compliance violations
- Increased attack surface

### Diagnosis
1. Check infinity token count:
   ```promql
   vault_token_count_by_ttl{creation_ttl="+Inf"} > 3
   ```

2. List tokens with infinite TTL:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault list auth/token/accessors
   ```

3. Get token details:
   ```bash
   # For each accessor
   kubectl exec -n vault <vault-pod> -- vault token lookup -accessor <accessor-id>
   ```

4. Identify token usage:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault token lookup -accessor <accessor-id> | grep -E "display_name|policies|creation_time"
   ```

### Mitigation
1. **Review each infinity token:**
   - Identify the purpose and owner
   - Verify if infinite TTL is necessary
   - Check last usage time

2. **Revoke unnecessary infinity tokens:**
   ```bash
   kubectl exec -n vault <vault-pod> -- vault token revoke -accessor <accessor-id>
   ```

3. **Replace with time-limited tokens:**
   ```bash
   # Create token with appropriate TTL (e.g., 30 days)
   kubectl exec -n vault <vault-pod> -- vault token create -ttl=720h -policy=<policy-name>
   ```

4. **Implement token lifecycle policy:**
   - Set maximum TTL for tokens
   - Use renewable tokens with periodic renewal
   - Implement token rotation

5. **Update Vault policies:**
   ```bash
   # Prevent creation of infinity tokens
   kubectl exec -n vault <vault-pod> -- vault write sys/auth/token/tune max_lease_ttl=8760h
   ```

6. **Audit token creation:**
   - Review who created infinity tokens
   - Update access controls
   - Implement approval process for long-lived tokens

---

## VaultClusterHealth

### Meaning
Less than 50% of Vault cluster nodes are active, indicating cluster health issues.

### Impact
- Reduced cluster redundancy
- Risk of service disruption
- Potential data unavailability
- Degraded performance

### Diagnosis
1. Check cluster health ratio:
   ```promql
   sum(vault_core_active) / count(vault_core_active) <= 0.5
   ```

2. Check all Vault pods:
   ```bash
   kubectl get pods -n vault -l app=vault
   kubectl get pods -n vault -o wide
   ```

3. Check Vault cluster status:
   ```bash
   # Check each pod
   for pod in $(kubectl get pods -n vault -l app=vault -o name); do
     echo "Checking $pod"
     kubectl exec -n vault $pod -- vault status
   done
   ```

4. Check HA status:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault operator raft list-peers
   ```

5. Check pod logs for errors:
   ```bash
   kubectl logs -n vault <vault-pod> | grep -i "error\|failed\|cluster"
   ```

### Mitigation
1. **Identify unhealthy nodes:**
   ```bash
   kubectl get pods -n vault -l app=vault
   kubectl describe pod -n vault <unhealthy-pod>
   ```

2. **Check for sealed nodes:**
   ```bash
   kubectl exec -n vault <vault-pod> -- vault status | grep Sealed
   ```

3. **Unseal sealed nodes** (see VaultSealed mitigation)

4. **Restart unhealthy pods:**
   ```bash
   kubectl delete pod -n vault <unhealthy-pod>
   ```

5. **Check storage backend:**
   - Verify Raft storage is healthy
   - Check persistent volumes
   - Verify network connectivity between nodes

6. **Check resource constraints:**
   ```bash
   kubectl top pods -n vault
   kubectl describe pod -n vault <vault-pod> | grep -A 5 Limits
   ```

7. **Review cluster configuration:**
   ```bash
   kubectl get configmap -n vault
   kubectl describe configmap -n vault <vault-config>
   ```

8. **Monitor cluster recovery:**
   ```bash
   watch kubectl get pods -n vault
   ```

---

## VaultNoActiveNode

### Meaning
No active Vault node in the cluster - complete cluster failure.

### Impact
- **Critical service outage**
- All Vault operations unavailable
- Applications cannot access secrets
- Complete loss of secret management
- Potential data access issues

### Diagnosis
1. Check for active nodes:
   ```promql
   sum(vault_core_active) == 0
   ```

2. Check all Vault pods:
   ```bash
   kubectl get pods -n vault
   kubectl get pods -n vault -o wide
   ```

3. Check Vault status on all pods:
   ```bash
   for pod in $(kubectl get pods -n vault -l app=vault -o name); do
     echo "=== $pod ==="
     kubectl exec -n vault $pod -- vault status 2>&1 || echo "Failed to get status"
   done
   ```

4. Check for seal status:
   ```bash
   kubectl logs -n vault <vault-pod> | grep -i "seal"
   ```

5. Check cluster events:
   ```bash
   kubectl get events -n vault --sort-by='.lastTimestamp'
   ```

### Mitigation
1. **Check if all nodes are sealed:**
   ```bash
   kubectl exec -n vault <vault-pod> -- vault status
   ```

2. **Unseal all Vault nodes** (see VaultSealed mitigation):
   ```bash
   # Unseal each pod with threshold keys
   for pod in $(kubectl get pods -n vault -l app=vault -o name); do
     echo "Unsealing $pod"
     kubectl exec -n vault $pod -- vault operator unseal <key1>
     kubectl exec -n vault $pod -- vault operator unseal <key2>
     kubectl exec -n vault $pod -- vault operator unseal <key3>
   done
   ```

3. **Check storage backend:**
   ```bash
   # Check Raft storage
   kubectl get pvc -n vault
   kubectl describe pvc -n vault <pvc-name>
   ```

4. **Verify network connectivity:**
   ```bash
   # Test connectivity between pods
   kubectl exec -n vault <vault-pod-1> -- nc -zv <vault-pod-2-ip> 8201
   ```

5. **Check for resource issues:**
   ```bash
   kubectl top pods -n vault
   kubectl describe nodes | grep -A 5 "Allocated resources"
   ```

6. **Restart Vault pods if necessary:**
   ```bash
   kubectl rollout restart statefulset -n vault vault
   ```

7. **Verify cluster recovery:**
   ```bash
   kubectl exec -n vault <vault-pod> -- vault operator raft list-peers
   ```

8. **Contact Vault administrator** if issue persists

---

## VaultHighBarrierLatency

### Meaning
Average latency for Vault barrier.get operations exceeds 300ms, indicating storage performance issues.

### Impact
- Slow secret retrieval
- Application performance degradation
- Increased response times
- User experience impact

### Diagnosis
1. Check barrier latency:
   ```promql
   rate(vault_barrier_get_sum[5m]) / rate(vault_barrier_get_count[5m]) > 0.3
   ```

2. Check Vault performance metrics:
   ```bash
   kubectl exec -n vault <vault-pod> -- vault read sys/metrics
   ```

3. Check storage backend performance:
   ```bash
   # For Raft storage
   kubectl exec -n vault <vault-pod> -- vault operator raft list-peers
   ```

4. Check I/O performance:
   ```bash
   kubectl exec -n vault <vault-pod> -- df -h
   kubectl top pods -n vault
   ```

5. Check for resource constraints:
   ```bash
   kubectl describe pod -n vault <vault-pod> | grep -A 10 "Limits\|Requests"
   ```

6. Review Vault logs:
   ```bash
   kubectl logs -n vault <vault-pod> | grep -i "slow\|latency\|performance"
   ```

### Mitigation
1. **Check storage performance:**
   - Verify persistent volume performance
   - Check for I/O bottlenecks
   - Review storage class configuration

2. **Optimize storage backend:**
   ```bash
   # Check Raft performance
   kubectl exec -n vault <vault-pod> -- vault operator raft autopilot state
   ```

3. **Increase resources if needed:**
   ```bash
   kubectl set resources statefulset -n vault vault \
     --limits=cpu=2,memory=4Gi \
     --requests=cpu=1,memory=2Gi
   ```

4. **Check for high load:**
   ```bash
   # Check request rate
   kubectl exec -n vault <vault-pod> -- vault read sys/metrics | grep vault_core_handle_request
   ```

5. **Optimize Vault configuration:**
   - Review cache settings
   - Adjust performance tuning parameters
   - Consider read replicas for read-heavy workloads

6. **Scale Vault cluster:**
   ```bash
   kubectl scale statefulset -n vault vault --replicas=5
   ```

7. **Monitor improvement:**
   ```bash
   # Watch metrics
   watch 'kubectl exec -n vault <vault-pod> -- vault read sys/metrics | grep barrier'
   ```

8. **Consider storage upgrade:**
   - Move to faster storage (SSD/NVMe)
   - Increase IOPS if using cloud storage
   - Review storage backend configuration

---

## General Vault Troubleshooting

### Check Vault Status
```bash
# Check all Vault pods
kubectl get pods -n vault

# Check Vault status
kubectl exec -n vault <vault-pod> -- vault status

# Check Vault version
kubectl exec -n vault <vault-pod> -- vault version

# Check Vault configuration
kubectl get configmap -n vault
kubectl describe configmap -n vault <vault-config>
```

### Check Vault HA Status
```bash
# Check HA status
kubectl exec -n vault <vault-pod> -- vault status | grep "HA Enabled"

# List Raft peers
kubectl exec -n vault <vault-pod> -- vault operator raft list-peers

# Check leader
kubectl exec -n vault <vault-pod> -- vault status | grep "HA Mode"
```

### Check Vault Metrics
```bash
# Get metrics
kubectl exec -n vault <vault-pod> -- vault read sys/metrics

# Check health endpoint
kubectl exec -n vault <vault-pod> -- curl http://localhost:8200/v1/sys/health
```

### Check Vault Audit Logs
```bash
# List audit devices
kubectl exec -n vault <vault-pod> -- vault audit list

# Check audit logs
kubectl logs -n vault <vault-pod> | grep audit
```

### Backup and Recovery
```bash
# Take Raft snapshot
kubectl exec -n vault <vault-pod> -- vault operator raft snapshot save /tmp/vault-snapshot.snap

# Copy snapshot
kubectl cp vault/<vault-pod>:/tmp/vault-snapshot.snap ./vault-snapshot.snap

# Restore from snapshot (if needed)
kubectl cp ./vault-snapshot.snap vault/<vault-pod>:/tmp/vault-snapshot.snap
kubectl exec -n vault <vault-pod> -- vault operator raft snapshot restore /tmp/vault-snapshot.snap
```

### Token Management
```bash
# List token accessors
kubectl exec -n vault <vault-pod> -- vault list auth/token/accessors

# Lookup token
kubectl exec -n vault <vault-pod> -- vault token lookup

# Revoke token
kubectl exec -n vault <vault-pod> -- vault token revoke <token-id>

# Create token
kubectl exec -n vault <vault-pod> -- vault token create -ttl=1h
```

### Policy Management
```bash
# List policies
kubectl exec -n vault <vault-pod> -- vault policy list

# Read policy
kubectl exec -n vault <vault-pod> -- vault policy read <policy-name>

# Write policy
kubectl exec -n vault <vault-pod> -- vault policy write <policy-name> <policy-file>
```

---

## Additional Resources
- Vault Documentation: https://www.vaultproject.io/docs
- Vault Operations: https://learn.hashicorp.com/collections/vault/operations
- Vault Security: https://www.vaultproject.io/docs/internals/security
- Vault Monitoring: https://www.vaultproject.io/docs/internals/telemetry
- Vault HA: https://www.vaultproject.io/docs/concepts/ha
- Monitoring Dashboard: Review Vault Grafana dashboards
- Vault Metrics: Monitor vault_* metrics in Prometheus