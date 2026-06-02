AppTraces
| where Message contains "fabric-mcp-agent"
| extend payload = parse_json(Message)
| project TimeGenerated, 
          payload.callerUpn, 
          payload.userQuery, 
          payload.assistantResponse,
          payload.subscriptionId,
          payload.backendLatencyMs
| order by TimeGenerated desc