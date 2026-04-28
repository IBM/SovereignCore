# Redis Alerts Runbook

## Overview
This runbook covers alerts related to Redis availability, performance, replication, and resource utilization.

---

## RedisDown

### Meaning
Redis instance is not responding or is down.

### Impact
- Critical service disruption
- Data access unavailable
- Application failures
- Cache unavailable

### Diagnosis
1. Check Redis status:
   ```promql
   redis_up == 0
   ```

2. Verify pod status:
   ```bash
   kubectl get pods -n <redis-namespace> -l app=redis
   kubectl describe pod -n <redis-namespace> <redis-pod>
   ```

3. Check pod logs:
   ```bash
   kubectl logs -n <redis-namespace> <redis-pod>
   kubectl logs -n <redis-namespace> <redis-pod> --previous
   ```

4. Check Redis service:
   ```bash
   kubectl get svc -n <redis-namespace>
   kubectl describe svc -n <redis-namespace> <redis-service>
   ```

### Mitigation
1. Restart Redis pod if crashed:
   ```bash
   kubectl delete pod -n <redis-namespace> <redis-pod>
   ```
2. Check for resource constraints
3. Review Redis configuration
4. Check persistent volume if using persistence
5. Verify network connectivity
6. Escalate if issue persists

---

## RedisMissingMaster

### Meaning
Redis cluster has no node marked as master - critical replication issue.

### Impact
- No write operations possible
- Cluster in degraded state
- Data consistency risk

### Diagnosis
1. Check master status:
   ```promql
   (count(redis_instance_info{role="master"}) or vector(0)) < 1
   ```

2. Check Redis replication info:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO replication
   ```

3. List all Redis instances and roles:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli ROLE
   ```

4. Check Redis Sentinel if used:
   ```bash
   kubectl exec -n <redis-namespace> <sentinel-pod> -- redis-cli -p 26379 SENTINEL masters
   ```

### Mitigation
1. Manually promote a replica to master:
   ```bash
   kubectl exec -n <redis-namespace> <redis-replica-pod> -- redis-cli REPLICAOF NO ONE
   ```
2. Update application configuration to point to new master
3. Reconfigure other replicas:
   ```bash
   kubectl exec -n <redis-namespace> <redis-replica-pod> -- redis-cli REPLICAOF <new-master-ip> 6379
   ```
4. If using Redis Sentinel, trigger failover:
   ```bash
   kubectl exec -n <redis-namespace> <sentinel-pod> -- redis-cli -p 26379 SENTINEL failover <master-name>
   ```
5. Review and fix root cause

---

## RedisTooManyMasters

### Meaning
Redis cluster has more than one node marked as master - split-brain scenario.

### Impact
- Data inconsistency risk
- Write conflicts
- Potential data loss
- Cluster integrity compromised

### Diagnosis
1. Check master count:
   ```promql
   count(redis_instance_info{role="master"}) > 1
   ```

2. Identify all masters:
   ```bash
   # Check each Redis instance
   for pod in $(kubectl get pods -n <redis-namespace> -l app=redis -o name); do
     echo "Checking $pod"
     kubectl exec -n <redis-namespace> $pod -- redis-cli ROLE
   done
   ```

3. Check replication configuration:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO replication
   ```

### Mitigation
1. **Immediate action - prevent data loss:**
   - Identify the correct master (most recent data)
   - Stop writes to incorrect masters

2. **Demote extra masters:**
   ```bash
   # Demote incorrect master to replica
   kubectl exec -n <redis-namespace> <incorrect-master-pod> -- \
     redis-cli REPLICAOF <correct-master-ip> 6379
   ```

3. **Verify replication:**
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO replication
   ```

4. **Fix Sentinel configuration if used:**
   ```bash
   kubectl exec -n <redis-namespace> <sentinel-pod> -- \
     redis-cli -p 26379 SENTINEL reset <master-name>
   ```

5. Review network partitioning issues
6. Implement proper quorum settings

---

## RedisDisconnectedSlaves

### Meaning
Not all Redis replicas are connected to the master.

### Impact
- Reduced redundancy
- Risk of data loss on failover
- Replication lag

### Diagnosis
1. Check disconnected replicas:
   ```promql
   count without (instance, job) (redis_connected_slaves) - sum without (instance, job) (redis_connected_slaves) - 1 > 0
   ```

2. Check replication status:
   ```bash
   kubectl exec -n <redis-namespace> <redis-master-pod> -- redis-cli INFO replication
   ```

3. Check replica connectivity:
   ```bash
   kubectl exec -n <redis-namespace> <redis-replica-pod> -- redis-cli PING
   ```

4. Check network connectivity:
   ```bash
   kubectl exec -n <redis-namespace> <redis-replica-pod> -- nc -zv <master-ip> 6379
   ```

### Mitigation
1. Restart disconnected replicas
2. Check network policies and connectivity
3. Verify master is accessible
4. Check for resource constraints on replicas
5. Review Redis logs for connection errors
6. Reconfigure replication if needed:
   ```bash
   kubectl exec -n <redis-namespace> <redis-replica-pod> -- \
     redis-cli REPLICAOF <master-ip> 6379
   ```

---

## RedisReplicationBroken

### Meaning
Redis instance has lost a replica - replication connection dropped.

### Impact
- Reduced redundancy
- Risk of data loss
- Potential failover issues

### Diagnosis
1. Check replication delta:
   ```promql
   delta(redis_connected_slaves[1m]) < 0
   ```

2. Check master replication info:
   ```bash
   kubectl exec -n <redis-namespace> <redis-master-pod> -- redis-cli INFO replication
   ```

3. Check replica logs:
   ```bash
   kubectl logs -n <redis-namespace> <redis-replica-pod>
   ```

### Mitigation
1. Identify which replica disconnected
2. Check replica pod status
3. Restart replica if needed
4. Verify network connectivity
5. Check for resource issues
6. Monitor replication lag after reconnection

---

## RedisClusterFlapping

### Meaning
Redis replica connections are unstable - frequent connect/disconnect cycles.

### Impact
- Unstable replication
- Potential data inconsistency
- Performance degradation
- Increased network traffic

### Diagnosis
1. Check connection changes:
   ```promql
   changes(redis_connected_slaves[1m]) > 1
   ```

2. Monitor replication status:
   ```bash
   watch -n 1 'kubectl exec -n <redis-namespace> <redis-master-pod> -- redis-cli INFO replication'
   ```

3. Check network stability
4. Review pod events:
   ```bash
   kubectl get events -n <redis-namespace> --sort-by='.lastTimestamp'
   ```

### Mitigation
1. Investigate network issues
2. Check for resource constraints causing pod restarts
3. Review Redis timeout configurations
4. Increase replication timeout if appropriate
5. Check for DNS resolution issues
6. Verify network policies

---

## RedisMissingBackup

### Meaning
Redis has not been backed up in the last 24 hours.

### Impact
- Risk of data loss
- No recovery point
- Compliance issues

### Diagnosis
1. Check last backup time:
   ```promql
   time() - redis_rdb_last_save_timestamp_seconds > 60 * 60 * 24
   ```

2. Check RDB save status:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli LASTSAVE
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO persistence
   ```

3. Check backup configuration:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG GET save
   ```

### Mitigation
1. Trigger manual backup:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli BGSAVE
   ```

2. Verify backup completed:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli LASTSAVE
   ```

3. Check persistent volume for RDB file
4. Review and fix backup configuration
5. Implement automated backup solution
6. Set up backup monitoring

---

## RedisOutOfSystemMemory

### Meaning
Redis is using more than 90% of system memory.

### Impact
- Risk of OOM kill
- Performance degradation
- Potential data loss
- Service instability

### Diagnosis
1. Check memory usage:
   ```promql
   redis_memory_used_bytes / redis_total_system_memory_bytes * 100 > 90
   ```

2. Check Redis memory info:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO memory
   ```

3. Check pod resource usage:
   ```bash
   kubectl top pod -n <redis-namespace> <redis-pod>
   ```

### Mitigation
1. Increase memory limits:
   ```bash
   kubectl set resources deployment -n <redis-namespace> <redis-deployment> \
     --limits=memory=4Gi
   ```

2. Configure maxmemory and eviction policy:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG SET maxmemory 3gb
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG SET maxmemory-policy allkeys-lru
   ```

3. Clear unnecessary keys
4. Review data retention policies
5. Consider scaling horizontally

---

## RedisOutOfConfiguredMaxmemory

### Meaning
Redis is using more than 90% of configured maxmemory limit.

### Impact
- Key eviction starting
- Potential data loss
- Performance impact
- Application errors

### Diagnosis
1. Check maxmemory usage:
   ```promql
   redis_memory_used_bytes / redis_memory_max_bytes * 100 > 90 and on(instance) redis_memory_max_bytes > 0
   ```

2. Check memory configuration:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG GET maxmemory
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG GET maxmemory-policy
   ```

3. Check eviction stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep evicted
   ```

### Mitigation
1. Increase maxmemory limit:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG SET maxmemory 4gb
   ```

2. Review eviction policy:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG SET maxmemory-policy allkeys-lru
   ```

3. Clear old/unused keys
4. Implement TTL on keys
5. Scale Redis cluster

---

## RedisTooManyConnections

### Meaning
Redis is using more than 90% of maximum allowed connections.

### Impact
- New connections rejected
- Application errors
- Service degradation

### Diagnosis
1. Check connection usage:
   ```promql
   redis_connected_clients / redis_config_maxclients * 100 > 90
   ```

2. Check current connections:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO clients
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CLIENT LIST
   ```

### Mitigation
1. Increase maxclients:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG SET maxclients 20000
   ```

2. Implement connection pooling in applications
3. Close idle connections
4. Review application connection management
5. Scale Redis if needed

---

## RedisNotEnoughConnections

### Meaning
Redis has fewer than 5 connections - potentially indicating service not in use or connectivity issues.

### Impact
- Service may not be utilized
- Potential connectivity problems
- Monitoring concern

### Diagnosis
1. Check connection count:
   ```promql
   redis_connected_clients < 5
   ```

2. Verify applications are running:
   ```bash
   kubectl get pods -n <app-namespace>
   ```

3. Test connectivity:
   ```bash
   kubectl exec -n <app-namespace> <app-pod> -- redis-cli -h <redis-service> PING
   ```

### Mitigation
1. Verify applications are configured correctly
2. Check network policies
3. Verify service discovery
4. Review application logs
5. Test manual connection

---

## RedisRejectedConnections

### Meaning
Redis is rejecting new connections - maxclients limit reached.

### Impact
- Application connection failures
- Service unavailable for new clients
- Critical service disruption

### Diagnosis
1. Check rejected connections:
   ```promql
   increase(redis_rejected_connections_total[1m]) > 0
   ```

2. Check connection stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep rejected
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG GET maxclients
   ```

### Mitigation
1. Immediately increase maxclients:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CONFIG SET maxclients 20000
   ```

2. Close idle connections:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli CLIENT KILL TYPE normal SKIPME yes
   ```

3. Implement connection pooling
4. Review application connection patterns
5. Scale Redis cluster

---

## RedisHighCommandsPerSec

### Meaning
Redis is processing more than 10,000 commands per second.

### Impact
- High load on Redis
- Potential performance degradation
- Resource consumption

### Diagnosis
1. Check command rate:
   ```promql
   rate(redis_commands_processed_total[1m]) > 10000
   ```

2. Check command stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO commandstats
   ```

3. Monitor slow log:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli SLOWLOG GET 10
   ```

### Mitigation
1. Verify if load is expected
2. Optimize application queries
3. Implement caching strategies
4. Scale Redis horizontally
5. Use Redis pipelining
6. Review command patterns

---

## RedisHighEvictedKeys

### Meaning
Redis is evicting more than 50 keys per second due to memory pressure.

### Impact
- Data loss (cached data)
- Cache misses increasing
- Performance degradation

### Diagnosis
1. Check eviction rate:
   ```promql
   sum(rate(redis_evicted_keys_total[5m])) by (instance) > 50
   ```

2. Check eviction stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep evicted
   ```

### Mitigation
1. Increase memory allocation
2. Review maxmemory-policy
3. Implement TTL on keys
4. Clean up unused keys
5. Scale Redis cluster

---

## RedisHighExpiredKeys

### Meaning
More than 50 keys per second are expiring.

### Impact
- High key turnover
- Potential performance impact
- May indicate TTL issues

### Diagnosis
1. Check expiration rate:
   ```promql
   sum(rate(redis_expired_keys_total[5m])) by (instance) > 50
   ```

2. Check expiration stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep expired
   ```

### Mitigation
1. Review TTL settings
2. Optimize key lifecycle
3. Adjust expiration policies
4. Monitor for expected behavior

---

## RedisLowKeyspaceHits

### Meaning
Redis keyspace hit rate is below 50 hits per second - low cache utilization.

### Impact
- Poor cache performance
- Increased backend load
- Inefficient caching

### Diagnosis
1. Check hit rate:
   ```promql
   irate(redis_keyspace_hits_total[5m]) < 50
   ```

2. Check hit/miss ratio:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep keyspace
   ```

### Mitigation
1. Review caching strategy
2. Warm up cache
3. Adjust TTL values
4. Review application access patterns

---

## RedisHighKeyspaceMisses

### Meaning
Redis is experiencing more than 50 cache misses per second.

### Impact
- Poor cache efficiency
- Increased backend load
- Performance degradation

### Diagnosis
1. Check miss rate:
   ```promql
   irate(redis_keyspace_misses_total[5m]) > 50
   ```

2. Calculate hit ratio:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep keyspace
   ```

### Mitigation
1. Review caching strategy
2. Increase cache size
3. Optimize key patterns
4. Implement cache warming
5. Review TTL settings

---

## RedisHighNetworkInput

### Meaning
Redis network input exceeds 10MB/sec.

### Impact
- High network utilization
- Potential bandwidth saturation
- Performance concerns

### Diagnosis
1. Check network input:
   ```promql
   rate(redis_net_input_bytes_total[5m]) > 10000000
   ```

2. Monitor network stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep net
   ```

### Mitigation
1. Verify if load is expected
2. Optimize data transfer
3. Use compression if applicable
4. Review network capacity
5. Scale if needed

---

## RedisHighNetworkOutput

### Meaning
Redis network output exceeds 10MB/sec.

### Impact
- High network utilization
- Potential bandwidth issues
- Performance impact

### Diagnosis
1. Check network output:
   ```promql
   rate(redis_net_output_bytes_total[5m]) > 10000000
   ```

2. Monitor network stats:
   ```bash
   kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO stats | grep net
   ```

### Mitigation
1. Verify if load is expected
2. Optimize queries to reduce data transfer
3. Implement pagination
4. Review network capacity
5. Scale horizontally

---

## General Redis Troubleshooting

### Check Redis Health
```bash
# Check Redis pods
kubectl get pods -n <redis-namespace> -l app=redis

# Check Redis service
kubectl get svc -n <redis-namespace>

# Test Redis connectivity
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli PING

# Get Redis info
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO
```

### Monitor Redis Performance
```bash
# Monitor commands in real-time
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli MONITOR

# Check slow log
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli SLOWLOG GET 10

# Get command statistics
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli INFO commandstats
```

### Backup and Restore
```bash
# Trigger backup
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli BGSAVE

# Check backup status
kubectl exec -n <redis-namespace> <redis-pod> -- redis-cli LASTSAVE

# Copy RDB file
kubectl cp <redis-namespace>/<redis-pod>:/data/dump.rdb ./dump.rdb
```

---

## Additional Resources
- Redis Documentation: https://redis.io/documentation
- Redis Commands: https://redis.io/commands
- Redis Best Practices: https://redis.io/topics/admin
- Monitoring Dashboard: Review Redis Grafana dashboards
- Redis Metrics: Monitor redis_* metrics in Prometheus