# Fabric MCP Agent — KQL Queries

Run from: **APIM → Monitoring → Logs** (queries the `onemtcww` Log Analytics workspace)

---

## Gateway logs — all traffic

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    ApimSubscriptionId,
    CallerUPN = tostring(BackendRequestHeaders["X-Caller-UPN"]),
    CallerIpAddress,
    ApiId,
    OperationId,
    Method,
    Url,
    ResponseCode,
    BackendTime,
    UserAgent
| order by TimeGenerated desc
```

## Usage by caller (last 24h)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| extend CallerUPN = tostring(BackendRequestHeaders["X-Caller-UPN"])
| summarize
    RequestCount = count(),
    AvgBackendMs = avg(BackendTime),
    P95BackendMs = percentile(BackendTime, 95),
    Errors = countif(ResponseCode >= 400)
  by CallerUPN
| order by RequestCount desc
```

## Error rate (timechart)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| summarize
    Total = count(),
    Errors = countif(ResponseCode >= 400),
    ErrorRate = round(100.0 * countif(ResponseCode >= 400) / count(), 2)
  by bin(TimeGenerated, 1h)
| render timechart
```

## Latency over time

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| summarize
    AvgBackendMs = avg(BackendTime),
    P95BackendMs = percentile(BackendTime, 95)
  by bin(TimeGenerated, 1h)
| render timechart
```