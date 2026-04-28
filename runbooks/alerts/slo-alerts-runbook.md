# SLO (Service Level Objective) Alerts Runbook

## Overview
This runbook covers alerts related to Service Level Objectives (SLO), specifically SSL/TLS certificate expiration monitoring for ingress and route endpoints. These alerts ensure that certificates are renewed before expiration to maintain service availability and security.

---

## SSLCertificateExpiringIn30Days/ SSLCertificateExpiringIn7Days

### Meaning
An SSL/TLS certificate for a monitored service will expire within 30 days in case of SSLCertificateExpiringIn30Days and 7 days in case of SSLCertificateExpiringIn7Days. This is an early warning to allow sufficient time for certificate renewal.

### Impact
- **Warning level**: Service continues to operate normally
- Potential service disruption if certificate expires
- Security warnings for users if certificate expires
- Loss of trust and compliance issues
- Time to plan and execute certificate renewal

### Diagnosis
1. Check which certificates are expiring:
   ```promql
   min by(service)((probe_ssl_earliest_cert_expiry - time()) / 86400) < 30
   ```

2. Get detailed certificate information:
   ```bash
   # Check certificate expiry for specific service
   kubectl get secret -n <namespace> <tls-secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
   ```

3. List all certificates and their expiry dates:
   ```bash
   # For ingress resources
   kubectl get ingress -A -o json | jq -r '.items[] | select(.spec.tls != null) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.tls[].secretName)"'
   
   # For route resources (OpenShift)
   kubectl get routes -A -o json | jq -r '.items[] | select(.spec.tls != null) | "\(.metadata.namespace)/\(.metadata.name)"'
   ```

4. Check blackbox exporter probe results:
   ```promql
   probe_ssl_earliest_cert_expiry{service="<service-name>"}
   ```

5. Verify certificate details from the endpoint:
   ```bash
   # Check certificate from external endpoint
   echo | openssl s_client -servername <hostname> -connect <hostname>:443 2>/dev/null | openssl x509 -noout -dates
   
   # Get full certificate details
   echo | openssl s_client -servername <hostname> -connect <hostname>:443 2>/dev/null | openssl x509 -noout -text
   ```

### Mitigation
1. **Identify the certificate owner and renewal process:**
   ```bash
   # Check certificate issuer
   kubectl get secret -n <namespace> <tls-secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer
   ```

2. **For cert-manager managed certificates:**
   ```bash
   # Check certificate resource
   kubectl get certificate -n <namespace>
   kubectl describe certificate -n <namespace> <cert-name>
   
   # Check certificate request status
   kubectl get certificaterequest -n <namespace>
   
   # Force certificate renewal
   kubectl annotate certificate -n <namespace> <cert-name> cert-manager.io/issue-temporary-certificate="true" --overwrite
   ```

3. **For manually managed certificates:**
   - Generate new certificate signing request (CSR)
   - Submit CSR to Certificate Authority
   - Obtain new certificate
   - Update Kubernetes secret:
     ```bash
     kubectl create secret tls <tls-secret-name> \
       --cert=path/to/tls.crt \
       --key=path/to/tls.key \
       --dry-run=client -o yaml | kubectl apply -n <namespace> -f -
     ```

4. **For Let's Encrypt certificates:**
   ```bash
   # Verify ACME challenge configuration
   kubectl get challenges -n <namespace>
   
   # Check cert-manager logs
   kubectl logs -n cert-manager deployment/cert-manager -f
   ```

5. **Verify certificate renewal:**
   ```bash
   # Check new certificate expiry
   kubectl get secret -n <namespace> <tls-secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
   
   # Verify certificate is being used
   curl -vI https://<hostname> 2>&1 | grep -A 10 "Server certificate"
   ```


---

## Common Troubleshooting

### Certificate Not Renewing Automatically

**Possible Causes:**
1. cert-manager not running or unhealthy
2. DNS validation failing (for Let's Encrypt)
3. Rate limits reached
4. Incorrect RBAC permissions
5. Network connectivity issues

**Diagnosis:**
```bash
# Check cert-manager health
kubectl get pods -n cert-manager
kubectl logs -n cert-manager deployment/cert-manager

# Check certificate status
kubectl describe certificate -n <namespace> <cert-name>

# Check challenges (for ACME/Let's Encrypt)
kubectl get challenges -n <namespace>
kubectl describe challenge -n <namespace> <challenge-name>

# Check orders
kubectl get orders -n <namespace>
```

### Certificate Chain Issues

**Symptoms:**
- Certificate appears valid but browsers show warnings
- Some clients can't connect

**Diagnosis:**
```bash
# Verify certificate chain
openssl s_client -showcerts -connect <hostname>:443 </dev/null

# Check if intermediate certificates are included
kubectl get secret -n <namespace> <tls-secret-name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -noout
```

### Blackbox Exporter Not Detecting Certificate

**Diagnosis:**
```bash
# Check blackbox exporter configuration
kubectl get configmap -n servicemonitors blackbox-exporter-config -o yaml

# Check probe configuration
kubectl get probe -n servicemonitors

# Test probe manually
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl -I https://<hostname>
```




---

## References
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
- [OpenSSL Certificate Commands](https://www.openssl.org/docs/man1.1.1/man1/x509.html)
- [Kubernetes TLS Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)