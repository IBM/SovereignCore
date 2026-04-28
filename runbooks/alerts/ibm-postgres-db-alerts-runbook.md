# IBM PostgreSQL Database Alerts Runbook

## Overview
This runbook covers alerts related to IBM PostgreSQL database health, performance, and availability monitoring.

---

## PostgresDatabaseGrowingFast

### Meaning
Database has grown more than 5GB in the last 30 minutes, indicating rapid data growth.

### Impact
- Risk of storage exhaustion
- Potential performance degradation
- Need for capacity planning

### Diagnosis
1. Check database growth rate:
   ```promql
   increase(cnpg_pg_database_size_bytes{datname=~".+"}[30m]) > 5e9
   ```
2. Identify which database is growing:
   ```bash
   kubectl exec -n <namespace> <postgres-pod> -- psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;"
   ```
3. Check for large tables:
   ```sql
   SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) 
   FROM pg_tables 
   ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC 
   LIMIT 10;
   ```

### Mitigation
1. Investigate data ingestion patterns
2. Review and optimize data retention policies
3. Consider archiving old data
4. Plan for storage expansion
5. Implement table partitioning if appropriate

---

## PostgresTransactionsSpike

### Meaning
Combined commit and rollback transaction rate has exceeded 5000 transactions per second.

### Impact
- High database load
- Potential performance issues
- Risk of resource exhaustion

### Diagnosis
1. Check transaction rate:
   ```promql
   (sum(irate(cnpg_pg_stat_database_xact_commit[5m])) + sum(irate(cnpg_pg_stat_database_xact_rollback[5m]))) > 5000
   ```
2. Identify active connections:
   ```sql
   SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;
   ```
3. Check for long-running transactions:
   ```sql
   SELECT pid, now() - xact_start AS duration, query 
   FROM pg_stat_activity 
   WHERE state != 'idle' 
   ORDER BY duration DESC;
   ```

### Mitigation
1. Review application workload patterns
2. Optimize transaction batching
3. Scale database resources if needed
4. Implement connection pooling
5. Review and optimize queries

---

## PostgresHighRowProcessing

### Meaning
PostgreSQL is processing more than 100,000 rows per second (fetched, returned, inserted, updated, deleted combined).

### Impact
- High database load
- Potential I/O bottleneck
- Performance considerations

### Diagnosis
1. Check row processing rate:
   ```promql
   sum(irate(cnpg_pg_stat_database_tup_fetched[5m]) + irate(cnpg_pg_stat_database_tup_returned[5m]) + irate(cnpg_pg_stat_database_tup_inserted[5m]) + irate(cnpg_pg_stat_database_tup_updated[5m]) + irate(cnpg_pg_stat_database_tup_deleted[5m])) > 100000
   ```
2. Identify top queries:
   ```sql
   SELECT query, calls, total_time, mean_time 
   FROM pg_stat_statements 
   ORDER BY total_time DESC 
   LIMIT 10;
   ```
3. Check table statistics:
   ```sql
   SELECT schemaname, tablename, n_tup_ins, n_tup_upd, n_tup_del 
   FROM pg_stat_user_tables 
   ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC;
   ```

### Mitigation
1. This is informational - verify if load is expected
2. Optimize queries if inefficient
3. Consider read replicas for read-heavy workloads
4. Implement caching strategies
5. Review indexing strategy

---

## PostgresBgwriterOverloaded

### Meaning
Background writer buffer allocation rate is high (>50,000/sec), suggesting checkpoint pressure or high write load.

### Impact
- Increased I/O pressure
- Potential performance degradation
- Risk of checkpoint spikes

### Diagnosis
1. Check buffer allocation rate:
   ```promql
   irate(cnpg_pg_stat_bgwriter_buffers_alloc[5m]) > 50000
   ```
2. Review checkpoint statistics:
   ```sql
   SELECT * FROM pg_stat_bgwriter;
   ```
3. Check shared_buffers configuration:
   ```sql
   SHOW shared_buffers;
   ```

### Mitigation
1. Increase shared_buffers if appropriate
2. Tune checkpoint settings (checkpoint_timeout, checkpoint_completion_target)
3. Review and optimize write-heavy queries
4. Consider increasing WAL buffers
5. Monitor I/O performance

---

## PostgresDeadlocksDetected

### Meaning
Database deadlocks have been detected in the last 5 minutes.

### Impact
- Transaction failures
- Application errors
- Data consistency concerns

### Diagnosis
1. Check deadlock count:
   ```promql
   increase(cnpg_pg_stat_database_deadlocks[5m]) > 0
   ```
2. Review PostgreSQL logs for deadlock details:
   ```bash
   kubectl logs -n <namespace> <postgres-pod> | grep -i deadlock
   ```
3. Identify conflicting queries
4. Review application transaction patterns

### Mitigation
1. Review and optimize transaction ordering
2. Reduce transaction duration
3. Implement retry logic in application
4. Review locking patterns
5. Consider using advisory locks where appropriate

---

## PostgresConflictsDetected

### Meaning
Lock conflicts have been detected in the last 5 minutes.

### Impact
- Query delays
- Potential transaction failures
- Performance degradation

### Diagnosis
1. Check conflict count:
   ```promql
   increase(cnpg_pg_stat_database_conflicts[5m]) > 0
   ```
2. Identify blocking queries:
   ```sql
   SELECT blocked_locks.pid AS blocked_pid,
          blocking_locks.pid AS blocking_pid,
          blocked_activity.query AS blocked_query,
          blocking_activity.query AS blocking_query
   FROM pg_catalog.pg_locks blocked_locks
   JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
   JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
   JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
   WHERE NOT blocked_locks.granted;
   ```

### Mitigation
1. Optimize long-running queries
2. Review transaction isolation levels
3. Implement query timeouts
4. Consider using NOWAIT or SKIP LOCKED
5. Review application locking patterns

---

## PostgresNoPrimary

### Meaning
No PostgreSQL primary instance is available - all instances are in recovery (read-only) mode.

### Impact
- Write operations unavailable
- Critical service disruption
- Data cannot be modified

### Diagnosis
1. Check replication status:
   ```promql
   sum by (namespace, job) (cnpg_pg_replication_in_recovery == 0) == 0
   ```
2. Verify cluster status:
   ```bash
   kubectl get cluster.pg.ibm.com -n <namespace>
   kubectl describe cluster.pg.ibm.com -n <namespace> <cluster-name>
   ```
3. Check pod status:
   ```bash
   kubectl get pods -n <namespace> -l pg.ibm.com/cluster=<cluster-name>
   ```

### Mitigation
1. Check IBM PG operator logs
2. Verify cluster configuration
3. If failover or promotion is required, use the IBM PG operator failover procedure approved for your environment
4. Review recent cluster events
5. Contact database administrator

---

## PostgresLowCacheHitRatio

### Meaning
PostgreSQL cache hit ratio has dropped below 95%, indicating excessive disk reads.

### Impact
- Increased I/O operations
- Performance degradation
- Slower query execution

### Diagnosis
1. Check cache hit ratio:
   ```promql
   (sum(rate(cnpg_pg_stat_database_blks_hit[5m])) / (sum(rate(cnpg_pg_stat_database_blks_hit[5m])) + sum(rate(cnpg_pg_stat_database_blks_read[5m])))) * 100 < 95
   ```
2. Review buffer cache statistics:
   ```sql
   SELECT sum(blks_hit) / (sum(blks_hit) + sum(blks_read)) * 100 AS cache_hit_ratio 
   FROM pg_stat_database;
   ```
3. Check shared_buffers size:
   ```sql
   SHOW shared_buffers;
   ```

### Mitigation
1. Increase shared_buffers if appropriate (typically 25% of RAM)
2. Review and optimize queries
3. Add missing indexes
4. Consider using pg_prewarm for frequently accessed data
5. Monitor working set size

---

## PostgresSlowReadIO

### Meaning
Block read time has exceeded 50ms, indicating slow disk read performance.

### Impact
- Query performance degradation
- Increased response times
- Poor user experience

### Diagnosis
1. Check read I/O time:
   ```promql
   cnpg_pg_stat_database_blk_read_time > 50
   ```
2. Review I/O statistics:
   ```sql
   SELECT datname, blk_read_time, blks_read 
   FROM pg_stat_database 
   WHERE blk_read_time > 0 
   ORDER BY blk_read_time DESC;
   ```
3. Check storage performance
4. Review slow queries

### Mitigation
1. Investigate storage performance issues
2. Optimize queries to reduce I/O
3. Add appropriate indexes
4. Consider faster storage (SSD/NVMe)
5. Review and tune I/O scheduler settings

---

## PostgresSlowWriteIO

### Meaning
Block write time has exceeded 50ms, indicating slow disk write performance.

### Impact
- Transaction commit delays
- Performance degradation
- Potential write bottleneck

### Diagnosis
1. Check write I/O time:
   ```promql
   cnpg_pg_stat_database_blk_write_time > 50
   ```
2. Review write statistics:
   ```sql
   SELECT datname, blk_write_time, blks_written 
   FROM pg_stat_database 
   WHERE blk_write_time > 0 
   ORDER BY blk_write_time DESC;
   ```
3. Check checkpoint activity
4. Monitor storage performance

### Mitigation
1. Investigate storage write performance
2. Tune checkpoint settings
3. Consider faster storage
4. Review WAL configuration
5. Optimize write-heavy operations

---

## PostgresReplicationLagHigh

### Meaning
Replication lag has exceeded 10 seconds between primary and replica.

### Impact
- Stale data on replicas
- Risk of data loss on failover
- Read replica inconsistency

### Diagnosis
1. Check replication lag:
   ```promql
   max(cnpg_pg_replication_lag) > 10
   ```
2. Review replication status:
   ```sql
   SELECT * FROM pg_stat_replication;
   ```
3. Check network connectivity between instances
4. Review replica resource utilization

### Mitigation
1. Check network connectivity and bandwidth
2. Verify replica has sufficient resources
3. Review and optimize write load on primary
4. Check for long-running queries on replica
5. Consider increasing wal_sender_timeout

---

## General PostgreSQL Troubleshooting

### Check Database Health
```bash
# Check cluster status
kubectl get cluster.pg.ibm.com -n <namespace>

# Check pod status
kubectl get pods -n <namespace> -l pg.ibm.com/cluster=<cluster-name>

# Check cluster events
kubectl describe cluster.pg.ibm.com -n <namespace> <cluster-name>

# View PostgreSQL logs
kubectl logs -n <namespace> <postgres-pod> -c postgres
```

### Performance Monitoring
```sql
-- Check active connections
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';

-- Check database size
SELECT pg_size_pretty(pg_database_size(current_database()));

-- Check table bloat
SELECT schemaname, tablename, 
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC 
LIMIT 10;

-- Check index usage
SELECT schemaname, tablename, indexname, idx_scan 
FROM pg_stat_user_indexes 
ORDER BY idx_scan ASC;
```

### Backup and Recovery
```bash
# Check backup status
kubectl get backup.pg.ibm.com -n <namespace>

# Trigger manual backup by creating a Backup custom resource
kubectl apply -n <namespace> -f - <<EOF
apiVersion: pg.ibm.com/v1
kind: Backup
metadata:
  name: manual-backup
spec:
  cluster:
    name: <cluster-name>
EOF

# Check scheduled backups
kubectl get scheduledbackup.pg.ibm.com -n <namespace>
```

---

## Additional Resources
- IBM PG operator documentation: https://github.ibm.com/ibm-pg/ibm-pg-operator
- PostgreSQL Documentation: https://www.postgresql.org/docs/
- Monitoring Dashboard: Review PostgreSQL Grafana dashboards
- IBM PG Operator Logs: Check operator logs for cluster management issues
