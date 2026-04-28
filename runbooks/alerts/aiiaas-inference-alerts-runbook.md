# AI Inference as a Service - Inference Cluster Alerts Runbook

## Overview
This runbook covers alerts related to AI Inference workloads running on dedicated inference clusters, including:
- vLLM inference engine performance and availability
- Request processing metrics (latency, throughput, error rates)
- Resource utilization (CPU, memory, GPU, KV cache)
- Cache performance

These alerts monitor the actual inference workloads in the `llms` namespace.

---

## AIInferenceHighErrorRate

### Meaning
The error rate for AI inference requests has exceeded 5% over the last 5 minutes.

### Impact
- Users experiencing inference failures
- Model quality or stability issues
- Potential service degradation

### Diagnosis
1. Check error rate by model:
   ```promql
   # Replace llms with the actual tenant namespace
   sum(rate(kserve_vllm:request_success_total{namespace="llms", finished_reason="error"}[5m])) by (model_name)
   / sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name)
   ```

2. Check inference service pods:
   ```bash
   # Replace llms with the actual tenant namespace
   NAMESPACE="llms"
   oc get pods -n $NAMESPACE

   # Get kserve pod name and describe it
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc describe pod -n $NAMESPACE $POD_NAME
   ```

3. Check pod logs for errors:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)

   # Note: vLLM logs may be verbose with INFO level messages (e.g., metrics requests)
   # Filter for errors, warnings, or specific issues
   oc logs -n $NAMESPACE $POD_NAME -c main --tail=500 | grep -i "error\|exception\|failed\|warning"

   # To see startup logs and configuration
   oc logs -n $NAMESPACE $POD_NAME -c main --tail=1000 | grep -v "GET /metrics"

   # To see all logs without metrics noise
   oc logs -n $NAMESPACE $POD_NAME -c main --tail=200 | grep -v "INFO.*GET /metrics"
   ```

4. Check request completion reasons:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name, finished_reason)
   ```

### Mitigation
1. Identify which models are experiencing errors
2. Check for resource constraints (GPU memory, KV cache)
3. Review recent model deployments or configuration changes
4. Check for invalid input patterns in logs
5. Verify model health (via service, as vLLM uses SSL):
   ```bash
   NAMESPACE="llms"
   # Access via service from another pod or use port-forward
   SVC=$(oc get svc -n $NAMESPACE -o json | jq -r '.items[] | select(.metadata.name | contains("workload")) | .metadata.name' | head -1)
   echo "Service: $SVC"
   # Note: vLLM is configured with SSL, use https when accessing
   ```
6. Consider restarting problematic pods:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc delete pod -n $NAMESPACE $POD_NAME
   ```

---

## AIInferenceLowSuccessRate

### Meaning
The success rate for AI inference requests has fallen below 90% over the last 5 minutes.

### Impact
- Critical service degradation
- Multiple users affected
- Potential model or infrastructure failure

### Diagnosis
1. Check success rate by model:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms", finished_reason="stop"}[5m])) by (model_name)
   / sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name)
   ```

2. Check all completion reasons:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (finished_reason)
   ```

3. Check pod status:
   ```bash
   NAMESPACE="llms"
   oc get pods -n $NAMESPACE -o wide
   ```

4. Check for pod restarts:
   ```bash
   NAMESPACE="llms"
   oc get pods -n $NAMESPACE -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
   ```

### Mitigation
1. Identify root cause from completion reasons (error, length, abort, etc.)
2. Check resource availability:
   ```bash
   NAMESPACE="llms"
   oc adm top pods -n $NAMESPACE
   oc adm top nodes
   ```
3. Check for GPU issues:
   ```bash
   NAMESPACE="llms"
   # GPU monitoring should be done via Prometheus metrics
   # Check GPU-related metrics from Prometheus or check node GPU status
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   NODE=$(oc get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.spec.nodeName}')
   echo "Pod is running on node: $NODE"
   # Check node GPU allocation
   oc describe node $NODE | grep -A 10 "Allocated resources"
   ```
4. Review KV cache usage (see AIInferenceHighKVCacheUsage)
5. Check for network issues affecting inference requests
6. Check for recent pod restarts:
   ```bash
   NAMESPACE="llms"
   oc get pods -n $NAMESPACE -o json | jq '.items[] | {name: .metadata.name, restarts: .status.containerStatuses[].restartCount, lastState: .status.containerStatuses[].lastState}'
   ```
7. Check if specific models are affected:
   - Review the "AI Inference as a Service - Inference Monitoring" dashboard
   - Most panels show metrics broken down by `model_name`
   - Look for patterns: is one model experiencing higher error rates than others?
8. Monitor trends over time using the **AI Inference as a Service - Inference Monitoring** dashboard or Prometheus queries to see if issue is improving or worsening

---

## AIInferenceHighLatency

### Meaning
The 95th percentile end-to-end request latency exceeds 30 seconds.

### Impact
- Poor user experience
- Slow inference responses
- Potential timeout issues

### Diagnosis
1. Check latency by model:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:e2e_request_latency_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

2. Check time to first token:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

3. Check inter-token latency:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:inter_token_latency_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

4. Check queue time:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:request_queue_time_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

5. Check resource usage:
   ```bash
   NAMESPACE="llms"
   oc adm top pods -n $NAMESPACE
   ```

### Mitigation
1. Identify latency bottleneck by checking the **AI Inference as a Service - Inference Monitoring** dashboard panels:
   - **Queue time**: "Request Queue Time (P95)" panel in "Model Health Status" section
   - **TTFT (Time to First Token)**: "Time to First Token (P95)" panel in "Request Metrics" section
   - **Generation**: "Inter-Token Latency (P95)" panel in "Inference Performance by Model" section
   - All these metrics are available in the "AI Inference as a Service - Inference Monitoring" dashboard
2. Check for resource constraints (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **CPU**: "CPU Usage" panel in "Resource Utilization" section
   - **Memory**: "Memory Usage" panel in "Resource Utilization" section
   - **GPU**: Check node-level GPU allocation (nvidia-smi not available in container)
3. Review concurrent request load (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Running requests**: "Requests in Execution" panel in "Inference Performance by Model" section
   - **Waiting requests**: "Requests Waiting" panel in "Model Health Status" section
4. Check KV cache usage (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **KV Cache**: "KV Cache Usage" panel in "Resource Utilization" section
   - High usage (>90%) can cause request preemptions and performance degradation
5. Consider scaling up model replicas if capacity issue (requires Control Plane access to modify ModelDeployment CR)
6. Review model configuration (requires Control Plane access to modify ModelDeployment CR)
7. Check for slow storage if model loading is slow (check pod events and logs)

---

## AIInferenceHighTimeToFirstToken

### Meaning
The 95th percentile time to first token exceeds 10 seconds.

### Impact
- Slow initial response
- Poor perceived performance
- User experience degradation

### Diagnosis
1. Check TTFT by model:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:time_to_first_token_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

2. Check prompt token processing rate:
   ```promql
   sum(rate(kserve_vllm:prompt_tokens_total{namespace="llms"}[5m])) by (model_name)
   ```

3. Check queue time contribution:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:request_queue_time_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

4. Check running requests:
   ```promql
   sum(kserve_vllm:num_requests_running{namespace="llms"}) by (model_name)
   ```

### Mitigation
1. Determine if delay is from queuing or processing (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Queue time**: "Request Queue Time (P95)" panel
   - **Processing time**: Compare TTFT with queue time
2. If queuing: consider scaling up replicas (requires Control Plane access to modify ModelDeployment CR)
3. If processing: check GPU utilization and KV cache (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **KV Cache**: "KV Cache Usage" panel in "Resource Utilization" section
4. Review prompt lengths (check "Prompt Tokens Processed" panel in **AI Inference as a Service - Inference Monitoring** dashboard)
5. Check prefix cache hit rate (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Cache hit rate**: "Prefix Cache Hit Rate" panel in "Inference Performance by Model" section
6. Verify GPU performance (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Throughput**: "Tokens per Second by Model" panel shows processing efficiency
   - **KV Cache**: "KV Cache Usage" panel indicates GPU memory utilization
   - **Preemptions**: "Request Preemptions" panel shows if GPU memory is constrained

---

## AIInferenceHighKVCacheUsage

### Meaning
KV cache usage has exceeded 90%.

### Impact
- Increased request preemptions
- Reduced throughput
- Potential request failures
- Performance degradation

### Diagnosis
1. Check KV cache usage by model:
   ```promql
   kserve_vllm:kv_cache_usage_perc{namespace="llms"}
   ```

2. Check preemption rate:
   ```promql
   sum(rate(kserve_vllm:num_preemptions_total{namespace="llms"}[5m])) by (model_name)
   ```

3. Check GPU blocks configuration:
   ```promql
   kserve_vllm:cache_config_info{namespace="llms"}
   ```

4. Check concurrent requests:
   ```promql
   sum(kserve_vllm:num_requests_running{namespace="llms"}) by (model_name)
   ```

### Mitigation
1. Monitor for request preemptions (indicates cache pressure)
2. Consider reducing max concurrent requests
3. Review model configuration for KV cache settings:
   ```bash
   NAMESPACE="llms"
   # Check vLLM configuration via environment variables
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc set env pod/${POD_NAME} -n $NAMESPACE --list | grep VLLM

   # Check current cache configuration from metrics
   # Dashboard: "Resource Utilization" section → "GPU Memory Blocks" panel
   # Shows: num_gpu_blocks, block_size, and other cache config

   # Check GPU resource allocation
   oc get pod ${POD_NAME} -n $NAMESPACE -o json | jq '.spec.containers[] | select(.name == "main") | .resources'
   ```
4. Check if requests have unusually long contexts:
   ```bash
   # Check prompt token metrics (average input size)
   # Dashboard: "Inference Performance by Model" section → "Prompt Tokens Processed" panel
   # Shows: Rate of prompt tokens processed per model

   # Check generation token metrics (average output size)
   # Dashboard: "Inference Performance by Model" section → "Generation Tokens Produced" panel
   # Shows: Rate of generation tokens produced per model

   # Calculate average tokens per request from metrics:
   # avg_prompt_tokens = rate(kserve_vllm:prompt_tokens_total) / rate(kserve_vllm:request_success_total)
   # avg_generation_tokens = rate(kserve_vllm:generation_tokens_total) / rate(kserve_vllm:request_success_total)

   # Check recent logs for token counts (if detailed logging is enabled)
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc logs ${POD_NAME} -n $NAMESPACE -c main --tail=100 | grep -i "token"
   ```
   **Note**: Unusually long contexts consume more KV cache memory. If average token counts are significantly higher than expected, consider:
   - Implementing request validation to reject overly long inputs at the application level
   - Reviewing application usage patterns to understand why long contexts are needed
5. Consider scaling up GPU memory if available (requires Control Plane access to modify ModelDeployment CR's resource allocation)
6. Consider adjusting vLLM configuration (requires Control Plane access):
   - vLLM parameters like `max_num_seqs` (max sequences in parallel) and `max_model_len` (max context length) are controlled by the platform
   - These settings are managed through the ModelDeployment CR's `spec.llmInferenceServiceSpec` field
   - Current settings can be viewed via `VLLM_ADDITIONAL_ARGS` environment variable (see step 3)
7. Implement request throttling at application level if necessary:
   - Rate limiting on the client/application side to control request volume
   - This is separate from vLLM configuration (step 6) which controls engine-level concurrency
   - Useful when demand exceeds available capacity

---

## AIInferenceHighPreemptionRate

### Meaning
Request preemption rate exceeds 1 per second, indicating resource constraints.

### Impact
- Requests being interrupted and restarted
- Increased latency
- Reduced throughput
- Poor user experience

### Diagnosis
1. Check preemption rate by model:
   ```promql
   sum(rate(kserve_vllm:num_preemptions_total{namespace="llms"}[5m])) by (model_name)
   ```

2. Check KV cache usage:
   ```promql
   kserve_vllm:kv_cache_usage_perc{namespace="llms"}
   ```

3. Check concurrent requests:
   ```promql
   sum(kserve_vllm:num_requests_running{namespace="llms"}) by (model_name)
   ```

4. Check waiting requests:
   ```promql
   sum(kserve_vllm:num_requests_waiting{namespace="llms"}) by (model_name)
   ```

### Mitigation
1. Primary cause is usually high KV cache usage (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **KV Cache**: "KV Cache Usage" panel shows current usage
   - **Preemptions**: "Request Preemptions" panel shows preemption rate
2. Reduce concurrent request limit (requires Control Plane access to modify ModelDeployment CR)
3. Scale up GPU memory if possible (requires Control Plane access to modify ModelDeployment CR)
4. Review request patterns (check "Prompt Tokens Processed" panel in **AI Inference as a Service - Inference Monitoring** dashboard)
5. Consider implementing request prioritization (requires Control Plane access to modify ModelDeployment CR)
6. Check if specific models are causing high load (all **AI Inference as a Service - Inference Monitoring** dashboard panels show breakdown by model_name)
7. Review ModelDeployment CR resource allocation (requires Control Plane access)

---

## AIInferenceHighQueueTime

### Meaning
The 95th percentile queue time exceeds 5 seconds.

### Impact
- Requests waiting too long before processing
- Increased overall latency
- Capacity issue

### Diagnosis
1. Check queue time by model:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:request_queue_time_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

2. Check waiting requests:
   ```promql
   sum(kserve_vllm:num_requests_waiting{namespace="llms"}) by (model_name)
   ```

3. Check running requests:
   ```promql
   sum(kserve_vllm:num_requests_running{namespace="llms"}) by (model_name)
   ```

4. Check request rate:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name)
   ```

### Mitigation
1. Indicates insufficient capacity for request load (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Queue depth**: "Requests Waiting" panel
   - **Request rate**: "Request Rate (all tenants)" panel
2. Scale up model replicas (requires Control Plane access to modify ModelDeployment CR)
3. Check if specific time periods have high load (use **AI Inference as a Service - Inference Monitoring** dashboard time range selector)
4. Review request patterns (check "Request Rate" and "Requests Waiting" trends in **AI Inference as a Service - Inference Monitoring** dashboard)
5. Implement request throttling at application level if necessary (rate limiting on client side to control request volume)
6. Consider auto-scaling based on queue depth (requires Control Plane access to configure auto-scaling in ModelDeployment CR)

---

## AIInferenceHighWaitingRequests

### Meaning
The number of waiting requests exceeds 10.

### Impact
- Request backlog building up
- Increased latency
- Capacity issue

### Diagnosis
1. Check waiting requests by model:
   ```promql
   sum(kserve_vllm:num_requests_waiting{namespace="llms"}) by (model_name)
   ```

2. Check running requests:
   ```promql
   sum(kserve_vllm:num_requests_running{namespace="llms"}) by (model_name)
   ```

3. Check request processing rate:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name)
   ```

4. Check queue time:
   ```promql
   histogram_quantile(0.95, sum(rate(kserve_vllm:request_queue_time_seconds_bucket{namespace="llms"}[5m])) by (le, model_name))
   ```

### Mitigation
1. Similar to high queue time - capacity issue (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Waiting requests**: "Requests Waiting" panel
   - **Running requests**: "Requests in Execution" panel
2. Scale up model replicas (requires Control Plane access to modify ModelDeployment CR)
3. Check for slow requests blocking the queue (check "P95 End-to-End Latency" panel in **AI Inference as a Service - Inference Monitoring** dashboard)
4. Review concurrent request limits (requires Control Plane access to modify ModelDeployment CR)
5. Consider implementing request prioritization (requires Control Plane access to modify ModelDeployment CR)
6. Check if specific models are causing high load (all **AI Inference as a Service - Inference Monitoring** dashboard panels show breakdown by model_name)

---

## AIInferenceLowThroughput

### Meaning
Token generation throughput is below 10 tokens per second.

### Impact
- Slow inference performance
- Underutilized resources
- Potential configuration issue

### Diagnosis
1. Check throughput by model:
   ```promql
   sum(rate(kserve_vllm:generation_tokens_total{namespace="llms"}[5m])) by (model_name)
   ```

2. Check request rate:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name)
   ```

3. Check if model is receiving requests:
   ```promql
   sum(kserve_vllm:num_requests_running{namespace="llms"}) by (model_name)
   ```

4. Check GPU utilization:
   ```bash
   NAMESPACE="llms"
   # Get the kserve pod name (not kserve-router)
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)

   # Check GPU from node (nvidia-smi not available in container)
   NODE=$(oc get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.spec.nodeName}')
   echo "Pod is running on node: $NODE"
   # Note: GPU monitoring should be done via Prometheus metrics, not nvidia-smi
   ```

### Mitigation
1. Verify model is receiving traffic (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Request rate**: "Request Rate (all tenants)" panel
   - **Requests running**: "Requests in Execution" panel
2. Check if this is expected (e.g., low usage period) - review **AI Inference as a Service - Inference Monitoring** dashboard time range
3. If GPU underutilized, investigate configuration (requires Control Plane access to review ModelDeployment CR)
4. Check for resource constraints (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **CPU**: "CPU Usage" panel
   - **Memory**: "Memory Usage" panel
5. Review model configuration settings (requires Control Plane access to review ModelDeployment CR)
6. Verify model is properly loaded and healthy (check pod logs and "Engine Sleep State" panel)

---

## AIInferenceHighCPUUsage

### Meaning
CPU usage exceeds 80%.

### Impact
- Potential performance degradation
- Risk of CPU throttling
- May affect request processing

### Diagnosis
1. Check CPU usage by pod:
   ```promql
   rate(kserve_process_cpu_seconds_total{namespace="llms"}[5m]) * 100
   ```

2. Check pod resource limits:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc describe pod -n $NAMESPACE $POD_NAME | grep -A 5 "Limits\|Requests"
   ```

3. Check top pods:
   ```bash
   NAMESPACE="llms"
   oc adm top pods -n $NAMESPACE
   ```

4. Check node CPU:
   ```bash
   oc adm top nodes
   ```

### Mitigation
1. Verify if CPU usage is expected for current load (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **CPU usage**: "CPU Usage" panel in "Resource Utilization" section
   - **Request rate**: "Request Rate (all tenants)" panel
2. Check if CPU limits are too restrictive:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc describe pod -n $NAMESPACE $POD_NAME | grep -A 5 "Limits\|Requests"
   ```
3. Consider increasing CPU limits in ModelDeployment CR (requires Control Plane access)
4. Check for CPU-intensive operations in logs:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc logs -n $NAMESPACE $POD_NAME -c main --tail=500 | grep -i "cpu\|performance"
   ```
5. Review model configuration (requires Control Plane access to review ModelDeployment CR)
6. Consider scaling horizontally if vertical scaling not sufficient (requires Control Plane access)

---

## AIInferenceHighMemoryUsage

### Meaning
Memory usage exceeds 90% of the configured memory limit.

### Impact
- Risk of OOM (Out of Memory) errors
- Potential pod eviction
- Performance degradation

### Diagnosis
1. Check memory usage ratio by pod:
   ```promql
   (kserve_process_resident_memory_bytes{namespace="llms"} / on(namespace, pod) kube_pod_container_resource_limits{namespace="llms", resource="memory", unit="byte"}) * 100
   ```

2. Check pod resource limits:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc describe pod -n $NAMESPACE $POD_NAME | grep -A 5 "Limits\|Requests"
   ```

3. Check top pods:
   ```bash
   NAMESPACE="llms"
   oc adm top pods -n $NAMESPACE
   ```

4. Check for memory leaks in logs:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc logs -n $NAMESPACE $POD_NAME -c main --tail=500 | grep -i "memory\|oom"
   ```

### Mitigation
1. Verify if the memory usage ratio is expected for the model size (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Memory usage**: "Memory Usage" panel in "Resource Utilization" section
   - Compare usage against the configured memory limit and expected model footprint
2. Check if memory limits are appropriate:
   ```bash
   NAMESPACE="llms"
   POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)
   oc describe pod -n $NAMESPACE $POD_NAME | grep -A 5 "Limits\|Requests"
   ```
3. Consider increasing memory limits in ModelDeployment CR (requires Control Plane access):
   - Memory limits are configured in ModelDeployment CR's `spec.llmInferenceServiceSpec.resources`
   - Ensure sufficient node memory is available before increasing limits
4. Check for memory leaks (increasing over time):
   - Monitor memory usage trend in **AI Inference as a Service - Inference Monitoring** dashboard over extended period
   - Look for steady increase without corresponding increase in load
   - Check pod restart history for OOM-related restarts:
     ```bash
     NAMESPACE="llms"
     oc get pods -n $NAMESPACE -o json | jq '.items[] | {name: .metadata.name, restarts: .status.containerStatuses[].restartCount, lastState: .status.containerStatuses[].lastState}'
     ```
5. Review KV cache configuration (uses significant memory):
   - **KV Cache usage**: "KV Cache Usage" panel in "Resource Utilization" section
   - High KV cache usage (>90%) combined with high memory usage may indicate need for adjustment
   - KV cache settings are managed through ModelDeployment CR's `spec.llmInferenceServiceSpec`
   - Consider reducing `max_num_seqs` or `max_model_len` if memory pressure is high (requires Control Plane access)
6. Consider using smaller batch sizes if applicable (requires Control Plane access to modify ModelDeployment CR)
7. Monitor for OOM events:
   ```bash
   NAMESPACE="llms"
   oc get events -n $NAMESPACE | grep -i "oom\|evict"

   # Check for recent OOM kills in pod status
   oc get pods -n $NAMESPACE -o json | jq '.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") | {name: .metadata.name, reason: .status.containerStatuses[].lastState.terminated.reason}'
   ```

---

## AIInferenceEngineSleeping

### Meaning
Inference engine is in sleep state.

### Impact
- Model not actively processing requests
- May indicate idle state or configuration issue
- Informational alert

### Diagnosis
1. Check engine sleep state:
   ```promql
   kserve_vllm:engine_sleep_state{namespace="llms", sleep_state="awake"}
   ```

2. Check if model is receiving requests:
   ```promql
   sum(rate(kserve_vllm:request_success_total{namespace="llms"}[5m])) by (model_name)
   ```

3. Check pod status:
   ```bash
   NAMESPACE="llms"
   oc get pods -n $NAMESPACE
   ```

### Mitigation
1. This is often expected during idle periods (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Engine state**: "Engine Sleep State" panel in "Model Health Status" section
   - **Request rate**: "Request Rate (all tenants)" panel
2. Verify model is accessible and healthy (check pod status and logs)
3. Check if this is a newly deployed model (check pod age)
4. If persistent and unexpected, check pod logs for errors
5. Verify model configuration allows sleep mode (requires Control Plane access to review ModelDeployment CR)
6. Consider if this is desired behavior for cost optimization

---

## AIInferenceLowCacheHitRate

### Meaning
Prefix cache hit rate is below 30%.

### Impact
- Reduced performance optimization
- More computation required
- Higher latency for repeated prompts
- Informational alert

### Diagnosis
1. Check cache hit rate by model:
   ```promql
   sum(rate(kserve_vllm:prefix_cache_hits_total{namespace="llms"}[5m])) by (model_name)
   / sum(rate(kserve_vllm:prefix_cache_queries_total{namespace="llms"}[5m])) by (model_name)
   ```

2. Check cache queries vs hits:
   ```promql
   sum(rate(kserve_vllm:prefix_cache_queries_total{namespace="llms"}[5m])) by (model_name)
   sum(rate(kserve_vllm:prefix_cache_hits_total{namespace="llms"}[5m])) by (model_name)
   ```

3. Review request patterns in logs

### Mitigation
1. Low hit rate may be expected if (view in **AI Inference as a Service - Inference Monitoring** dashboard):
   - **Cache metrics**: "Prefix Cache Hit Rate" and "Cache Queries vs Hits" panels
   - Requests have diverse prompts (check "Prompt Tokens Processed" panel)
   - Cache is cold (recently started - check pod age)
   - Prefix caching not beneficial for use case
2. Verify prefix caching is enabled in model configuration (requires Control Plane access to review ModelDeployment CR)
3. Review if request patterns could benefit from caching (analyze "Cache Queries vs Hits" panel trends)
4. Consider if this is expected behavior
5. No immediate action needed unless performance is impacted (check "P95 End-to-End Latency" panel)

---

## General Troubleshooting Steps

### Check Inference Service Health
```bash
# Replace llms with the actual tenant namespace
NAMESPACE="llms"

# Check all pods in namespace
oc get pods -n $NAMESPACE

# Get the kserve pod name (not kserve-router)
POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)

# Check pod logs (main container runs vLLM)
# Note: Logs may be verbose with metrics requests, filter as needed
oc logs -n $NAMESPACE $POD_NAME -c main --tail=100 | grep -v "GET /metrics"

# Check for errors in logs
oc logs -n $NAMESPACE $POD_NAME -c main --tail=500 | grep -i "error\|warning\|exception"

# Check pod events
oc describe pod -n $NAMESPACE $POD_NAME

# Check service endpoints
oc get endpoints -n $NAMESPACE

# Check pod resource usage
oc adm top pods -n $NAMESPACE
```

### Check Metrics
```bash
NAMESPACE="llms"

# Get the kserve pod name (not kserve-router)
POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)

# Port forward to metrics endpoint (vLLM uses SSL)
oc port-forward -n $NAMESPACE $POD_NAME 8000:8000

# In another terminal, query metrics (note: vLLM is configured with SSL)
# Use -k to skip certificate verification for self-signed certs
curl -k https://localhost:8000/metrics | grep kserve_vllm

# Check specific metrics
curl -k https://localhost:8000/metrics | grep kserve_vllm:request_success_total
curl -k https://localhost:8000/metrics | grep kserve_vllm:e2e_request_latency_seconds
curl -k https://localhost:8000/metrics | grep kserve_vllm:kv_cache_usage_perc

# Alternatively, access via service (from within cluster)
SVC=$(oc get svc -n $NAMESPACE -o json | jq -r '.items[] | select(.metadata.name | contains("workload")) | .metadata.name' | head -1)
echo "Metrics available via service: https://$SVC:8000/metrics"
```

### Check GPU Status
```bash
NAMESPACE="llms"

# Note: nvidia-smi is not available in the vLLM container
# GPU monitoring should be done via Prometheus metrics or node-level monitoring

# Get the kserve pod name
POD_NAME=$(oc get pods -n $NAMESPACE --field-selector=status.phase=Running -o json | jq -r '.items[] | select(.metadata.name | contains("router") | not) | select(.metadata.name | contains("kserve")) | .metadata.name' | head -1)

# Check which node the pod is running on
NODE=$(oc get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.spec.nodeName}')
echo "Pod is running on node: $NODE"

# Check GPU allocation on the node
oc describe node $NODE | grep -i gpu

# For GPU metrics, use Prometheus queries or check vLLM metrics
```

### Check Model Configuration
```bash
NAMESPACE="llms"

# Check InferenceService on the inference cluster
oc get inferenceservice -n $NAMESPACE

# Check model configuration
oc get configmap -n $NAMESPACE

# Note: ModelDeployment CRs (sovereign.cloud.ibm.com/v1) are managed on the Control Plane (Hub Cluster)
# To view or modify ModelDeployment CRs, you need access to the Control Plane cluster
# Example: oc get modeldeployments -n <aiiaas-namespace> (on Control Plane)
```

### Resource Monitoring
```bash
NAMESPACE="llms"

# Check resource usage
oc adm top pods -n $NAMESPACE
oc adm top nodes

# Check resource limits
oc describe pod -n $NAMESPACE <pod-name> | grep -A 5 Limits

# Check resource requests
oc describe pod -n $NAMESPACE <pod-name> | grep -A 5 Requests

# Check node resources
oc describe node <node-name> | grep -A 10 "Allocated resources"
```

### Check Network and Routes
```bash
# Check routes
oc get route -n openshift-ingress aiiaas-inference

# Check route status
oc describe route -n openshift-ingress aiiaas-inference

# Test inference endpoint
curl -k https://<inference-endpoint>/health
```

### Check Related Resources
```bash
NAMESPACE="llms"

# Check PVCs
oc get pvc -n $NAMESPACE

# Check secrets
oc get secrets -n $NAMESPACE

# Check configmaps
oc get configmap -n $NAMESPACE

# Check network policies
oc get networkpolicy -n $NAMESPACE
```

---

---

## Additional Resources

### Documentation
- IBM Sovereign Core Architecture documentation
- AI Inference as a Service (AIIaaS) documentation
- vLLM documentation: https://docs.vllm.ai/
- KServe documentation: https://kserve.github.io/website/

### Related Runbooks
- Control Plane AIIaaS alerts: See related runbook for aiiaas-operator, aiiaas-model-gateway, and aiiaas-service-broker
- Platform Core Services alerts: See common-service-broker-alerts-runbook.md
- Cluster infrastructure alerts: See cluster-as-a-service-alerts-runbook.md

### Dashboards
- AI Inference as a Service - Inference Monitoring (for inference cluster metrics)
- AI Inference as a Service - Control Plane Monitoring (for Control Plane component metrics)

### Architecture Reference
- **Control Plane (Hub Cluster)**: Hosts AIIaaS controllers and Service Delivery Layer components
- **Dedicated Inference Clusters**: Run actual inference workloads in tenant-specific namespaces
- **Service Delivery Layer**: Includes both Control Plane controllers and inference cluster workloads

