# Egress Traffic Alerts Runbook

## Overview
This runbook covers alerts related to egress network traffic monitoring, specifically traffic leaving the defined CIDR ranges.

---

## Egress_Traffic_Seen

### Meaning
Egress traffic going outside the defined CIDR range has been detected for more than 2 minutes.

### Impact
- Potential security concern
- Unexpected external communication
- Possible data exfiltration
- Compliance violation risk

### Diagnosis
1. Check egress traffic rate:
   ```promql
   sum(irate(netobserv_egress_traffic_ip_counter[1m])) >= 1
   ```

2. Review Network Observability dashboard:
   - Access the runbook link provided in the alert
   - Filter for egress traffic patterns
   - Identify source pods/services

3. Identify source of egress traffic:
   ```bash
   # Check pods with external connectivity
   kubectl get pods -A -o wide
   
   # Review network policies
   kubectl get networkpolicy -A
   ```

4. Check Network Observability flows:
   - Review the NetFlow traffic dashboard
   - Filter by destination IPs outside CIDR range
   - Identify source workloads

5. Verify if traffic is legitimate:
   - Check if pods need external API access
   - Review application requirements
   - Verify against approved external endpoints

### Mitigation

#### If Traffic is Legitimate:
1. Document the external endpoint requirement
2. Update network policies to explicitly allow:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-external-api
     namespace: <namespace>
   spec:
     podSelector:
       matchLabels:
         app: <app-name>
     policyTypes:
     - Egress
     egress:
     - to:
       - ipBlock:
           cidr: <external-ip>/32
       ports:
       - protocol: TCP
         port: 443
   ```
3. Update monitoring exceptions if needed
4. Document in security review

#### If Traffic is Suspicious:
1. **Immediate actions:**
   - Isolate the affected pod:
     ```bash
     kubectl label pod -n <namespace> <pod-name> quarantine=true
     ```
   - Apply restrictive network policy:
     ```yaml
     apiVersion: networking.k8s.io/v1
     kind: NetworkPolicy
     metadata:
       name: quarantine-pod
       namespace: <namespace>
     spec:
       podSelector:
         matchLabels:
           quarantine: "true"
       policyTypes:
       - Egress
       - Ingress
       egress: []
       ingress: []
     ```
   - Capture pod logs immediately:
     ```bash
     kubectl logs -n <namespace> <pod-name> > /tmp/suspicious-pod-logs.txt
     ```

2. **Investigation:**
   - Review pod logs for suspicious activity
   - Check process list in container:
     ```bash
     kubectl exec -n <namespace> <pod-name> -- ps aux
     ```
   - Inspect network connections:
     ```bash
     kubectl exec -n <namespace> <pod-name> -- netstat -an
     ```
   - Check for unauthorized processes or binaries
   - Review recent deployments or changes

3. **Security response:**
   - Contact security team immediately
   - Preserve evidence (logs, network captures)
   - Review access logs and audit trails
   - Check for compromised credentials
   - Scan for malware or backdoors

4. **Remediation:**
   - Delete compromised pod:
     ```bash
     kubectl delete pod -n <namespace> <pod-name>
     ```
   - Review and update container images
   - Rotate credentials and secrets
   - Implement additional security controls
   - Update network policies to prevent recurrence

#### If Traffic is Misconfigured:
1. Review application configuration
2. Update service endpoints to use internal services
3. Fix DNS resolution issues
4. Update network policies
5. Test connectivity after changes

### Prevention

1. **Network Policy Best Practices:**
   ```yaml
   # Default deny all egress
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-egress
     namespace: <namespace>
   spec:
     podSelector: {}
     policyTypes:
     - Egress
   ```

2. **Implement egress gateway:**
   - Route all external traffic through controlled gateway
   - Monitor and log all egress traffic
   - Implement allow-list for external endpoints

3. **Regular audits:**
   - Review network policies regularly
   - Audit external connectivity requirements
   - Monitor egress traffic patterns
   - Update security baselines

4. **Security controls:**
   - Implement pod security policies/standards
   - Use admission controllers to enforce policies
   - Regular vulnerability scanning
   - Implement runtime security monitoring

---

## Network Observability Troubleshooting

### Check Network Observability Setup
```bash
# Check Network Observability operator
kubectl get pods -n netobserv

# Check FlowCollector configuration
kubectl get flowcollector -A

# Check Network Observability console plugin
kubectl get consoleplugin netobserv-plugin
```

### Access Network Flow Data
```bash
# Port-forward to Network Observability console
kubectl port-forward -n netobserv svc/netobserv-plugin 9001:9001

# Access via OpenShift Console
# Navigate to: Observe > Network Traffic
```

### Query Network Flows
```bash
# Check recent flows (if using Loki)
kubectl exec -n netobserv <loki-pod> -- logcli query '{app="netobserv-flowlogs-pipeline"}' --limit=100

# Check flow metrics
kubectl get --raw /api/v1/namespaces/netobserv/services/flowmetrics:9090/proxy/api/v1/query?query=netobserv_egress_traffic_ip_counter
```

### Network Policy Debugging
```bash
# List all network policies
kubectl get networkpolicy -A

# Describe specific policy
kubectl describe networkpolicy -n <namespace> <policy-name>

# Test connectivity from pod
kubectl exec -n <namespace> <pod-name> -- curl -v <destination>

# Check if traffic is blocked
kubectl exec -n <namespace> <pod-name> -- nc -zv <destination-ip> <port>
```

### Capture Network Traffic
```bash
# Capture traffic from specific pod
kubectl debug -n <namespace> <pod-name> -it --image=nicolaka/netshoot -- tcpdump -i any -w /tmp/capture.pcap

# Analyze captured traffic
kubectl cp <namespace>/<debug-pod>:/tmp/capture.pcap ./capture.pcap
wireshark capture.pcap
```

---

## Additional Resources
- Network Observability Documentation: https://docs.openshift.com/container-platform/latest/networking/network_observability/network-observability-overview.html
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Security Best Practices: Review internal security documentation
- Incident Response: Follow security incident response procedures
- NetFlow Dashboard: Access via alert runbook_link