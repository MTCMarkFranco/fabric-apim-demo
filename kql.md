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

---

## LLM Prompts & Responses (Log LLM Messages)

### All prompts and responses — last 24h

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(RequestBody) or isnotempty(ResponseBody)
| extend CallerUPN = tostring(BackendRequestHeaders["X-Caller-UPN"])
| project
    TimeGenerated,
    CallerUPN,
    OperationId,
    Prompt = RequestBody,
    Response = ResponseBody,
    ResponseCode,
    BackendTime
| order by TimeGenerated desc
```

### Prompts and responses with parsed JSON content

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(RequestBody)
| extend CallerUPN = tostring(BackendRequestHeaders["X-Caller-UPN"])
| extend ParsedRequest = parse_json(RequestBody)
| extend ParsedResponse = parse_json(ResponseBody)
| project
    TimeGenerated,
    CallerUPN,
    UserMessage = tostring(ParsedRequest.messages[-1].content),
    AssistantResponse = tostring(ParsedResponse.choices[0].message.content),
    TokensUsed = toint(ParsedResponse.usage.total_tokens),
    ResponseCode,
    BackendTime
| order by TimeGenerated desc
```

### LLM usage by caller — token consumption

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where isnotempty(ResponseBody)
| extend CallerUPN = tostring(BackendRequestHeaders["X-Caller-UPN"])
| extend ParsedResponse = parse_json(ResponseBody)
| extend
    PromptTokens = toint(ParsedResponse.usage.prompt_tokens),
    CompletionTokens = toint(ParsedResponse.usage.completion_tokens),
    TotalTokens = toint(ParsedResponse.usage.total_tokens)
| summarize
    Requests = count(),
    TotalPromptTokens = sum(PromptTokens),
    TotalCompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens)
  by CallerUPN
| order by TotalTokens desc
```

### Search prompts for specific content

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where RequestBody has "vanilla" or ResponseBody has "vanilla"
| extend CallerUPN = tostring(BackendRequestHeaders["X-Caller-UPN"])
| project
    TimeGenerated,
    CallerUPN,
    Prompt = RequestBody,
    Response = ResponseBody
| order by TimeGenerated desc
```