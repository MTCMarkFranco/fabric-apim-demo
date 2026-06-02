# Fabric MCP Data Agent — API Management Gateway

This project configures Azure API Management (APIM) as a secure gateway in front of a Microsoft Fabric Data Agent MCP endpoint. APIM handles pre-authentication (Entra ID token validation), observability (Log Analytics + App Insights), and subscription-based access tracking.

## Architecture

```
┌──────────────┐     ┌───────────────────┐     ┌─────────────────────────┐
│  MCP Client  │────▶│  Azure API Mgmt   │────▶│  Fabric Data Agent MCP  │
│ (VS Code,    │     │  fabric-ai-demo-  │     │  (Finance Agent)        │
│  Claude,     │     │  pcc              │     │                         │
│  curl)       │     │                   │     │  Workspace: 3a074a45... │
└──────────────┘     └───────────────────┘     └─────────────────────────┘
       │                      │
       │ Bearer Token         │ Logs to App Insights
       │ + Subscription Key   │ → Log Analytics
       │                      │ Custom Metrics
```

## Endpoints

| Endpoint | URL |
|----------|-----|
| **APIM Gateway** | `https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp` |
| **Direct Fabric** | `https://api.fabric.microsoft.com/v1/mcp/workspaces/3a074a45-be8c-4556-8866-bb3c81327a6b/dataagents/46e225d0-6029-4491-a943-76f6dc33ca1f/agent` |

## Prerequisites

- Azure CLI installed and signed in (`az login`)
- Access to the `onemtc.net` tenant (tenant ID: `32dc2feb-7716-4cf8-b1a6-f02cf37fd6bf`)
- APIM subscription key (subscription: `Biz-Group-1`)
- Permissions to access the Fabric workspace

---

## 1. Testing in APIM Portal

### Steps

1. Navigate to **Azure Portal** → **API Management** → `fabric-ai-demo-pcc`
2. Go to **APIs** → `Fabric MCP Data Agent` → **MCP Endpoint** → **Test** tab
3. Select subscription **Biz-Group-1** from the dropdown
4. Add header:
   - **Name:** `Authorization`
   - **Value:** `Bearer <token>` (see [Getting a Token](#getting-a-bearer-token) below)
5. Set **Request body** to raw JSON:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "DataAgent_Finance_Agent",
    "arguments": {
      "userQuestion": "Which product had the highest sales and who is the customer that bought the most of that product?"
    }
  }
}
```

6. Click **Send**
7. Check the **Trace** tab at the bottom for the full policy execution trace

---

## 2. Calling from cURL

### Getting a Bearer Token

```bash
# Login to the onemtc.net tenant
az login --tenant onemtc.net --allow-no-subscriptions

# Get the token
TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
```

### Making the Request

```bash
curl -X POST "https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Ocp-Apim-Subscription-Key: <your-biz-group-1-subscription-key>" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "DataAgent_Finance_Agent",
      "arguments": {
        "userQuestion": "Which product had the highest sales?"
      }
    }
  }'
```

### PowerShell Equivalent

```powershell
$token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
    "Ocp-Apim-Subscription-Key" = "<your-biz-group-1-subscription-key>"
}

$body = @{
    jsonrpc = "2.0"
    id = 1
    method = "tools/call"
    params = @{
        name = "DataAgent_Finance_Agent"
        arguments = @{
            userQuestion = "Which product had the highest sales?"
        }
    }
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp" -Method POST -Headers $headers -Body $body
```

---

## 3. VS Code Configuration

The `.vscode/mcp.json` file connects VS Code's MCP client directly to the Fabric endpoint (bypassing APIM for local dev):

```json
{
  "inputs": [
    {
      "type": "promptString",
      "id": "fabric-token",
      "description": "Fabric API Bearer Token (from az account get-access-token --resource https://api.fabric.microsoft.com)",
      "password": true
    }
  ],
  "servers": {
    "Fabric Finance Agent MCP server": {
      "type": "http",
      "url": "https://api.fabric.microsoft.com/v1/mcp/workspaces/3a074a45-be8c-4556-8866-bb3c81327a6b/dataagents/46e225d0-6029-4491-a943-76f6dc33ca1f/agent",
      "headers": {
        "Authorization": "Bearer ${input:fabric-token}"
      }
    }
  }
}
```

When prompted for the token, run:

```bash
az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
```

---

## 4. Claude Desktop / Claude Code Configuration

Claude Desktop and Claude Code support MCP servers with OAuth-based authentication. To configure Fabric MCP with corporate credentials (Entra ID), you need to set up the MCP server with the Azure AD OAuth provider.

### Claude Code (`~/.claude/claude_desktop_config.json` or project `.mcp.json`)

```json
{
  "mcpServers": {
    "fabric-finance-agent": {
      "type": "streamable-http",
      "url": "https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp",
      "headers": {
        "Ocp-Apim-Subscription-Key": "<your-biz-group-1-subscription-key>"
      },
      "auth": {
        "type": "azure_entra",
        "tenantId": "32dc2feb-7716-4cf8-b1a6-f02cf37fd6bf",
        "clientId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46",
        "scope": "https://api.fabric.microsoft.com/.default"
      }
    }
  }
}
```

> **Note:** The `clientId` above (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) is the Azure CLI's well-known public client app ID. If your organization has a dedicated app registration for this MCP integration, replace it with that app's client ID.

### Configuration Properties Explained

| Property | Value | Purpose |
|----------|-------|---------|
| `type` | `streamable-http` | HTTP-based MCP transport |
| `url` | `https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp` | APIM gateway endpoint |
| `auth.type` | `azure_entra` | Microsoft Entra ID (Azure AD) authentication |
| `auth.tenantId` | `32dc2feb-7716-4cf8-b1a6-f02cf37fd6bf` | onemtc.net tenant |
| `auth.clientId` | App registration client ID | The app used for the OAuth device code / interactive flow |
| `auth.scope` | `https://api.fabric.microsoft.com/.default` | Fabric API scope — ensures the token audience matches what APIM validates |
| `headers.Ocp-Apim-Subscription-Key` | Subscription key | APIM subscription for tracking |

### Setup Steps for Claude Desktop

1. **Locate config file:**
   - **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
   - **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`

2. **Add the server config** from the JSON block above to the `mcpServers` section

3. **Restart Claude Desktop** — it will detect the new MCP server

4. **Authenticate:** On first use, Claude will trigger the corporate login flow (device code or browser redirect). Sign in with your `@onemtc.net` credentials.

5. **Verify:** Ask Claude a question like _"Which product had the highest sales?"_ — it should invoke the Fabric Finance Agent tool

### If `azure_entra` auth type is not supported

If your version of Claude doesn't support `azure_entra` natively, use a token-helper approach:

```json
{
  "mcpServers": {
    "fabric-finance-agent": {
      "type": "streamable-http",
      "url": "https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp",
      "headers": {
        "Ocp-Apim-Subscription-Key": "<your-biz-group-1-subscription-key>",
        "Authorization": "Bearer <paste-token-here>"
      }
    }
  }
}
```

Generate the token with:

```bash
az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
```

> **Limitation:** Tokens expire after ~1 hour. You'll need to refresh and update the config periodically.

---

## 5. Observability & Logging

All requests through APIM are logged to Application Insights / Log Analytics with:

| Field | Source | Description |
|-------|--------|-------------|
| `callerUpn` | JWT `upn` claim | Who made the request |
| `subscriptionId` | APIM subscription | Which business group |
| `userQuery` | MCP request body | The question asked |
| `assistantResponse` | MCP response body | The agent's answer (truncated to 4KB) |
| `backendLatencyMs` | APIM timing | Round-trip to Fabric |
| `operationId` | APIM request ID | Correlation ID |

### KQL Query for Log Analytics

```kql
AppTraces
| where Message contains "fabric-mcp-agent"
| extend payload = parse_json(Message)
| project
    TimeGenerated,
    CallerUPN = tostring(payload.callerUpn),
    UserQuery = tostring(payload.userQuery),
    AssistantResponse = tostring(payload.assistantResponse),
    SubscriptionId = tostring(payload.subscriptionId),
    LatencyMs = toint(payload.backendLatencyMs),
    OperationId = tostring(payload.operationId)
| order by TimeGenerated desc
```

### Custom Metrics (Azure Monitor)

- **Namespace:** `Fabric MCP Agent`
- **Metrics:** `fabric-mcp-request`, `fabric-mcp-response`, `fabric-mcp-error`
- **Dimensions:** Subscription ID, Caller UPN, MCP Method, Status Code

---

## Project Structure

```
fabric-pcc/
├── .vscode/
│   └── mcp.json                    # VS Code MCP server config
├── policies/
│   └── fabric-mcp-inbound.xml      # APIM policy (paste into portal)
├── kql.md                          # KQL queries reference
└── README.md                       # This file
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `401 Unauthorized` from APIM | Token expired — regenerate with `az account get-access-token` |
| `401` with valid token | Check tenant ID in token matches `32dc2feb-...` (onemtc.net) |
| `403 Forbidden` from Fabric | Your user needs access to the Fabric workspace |
| No logs in Log Analytics | Ensure App Insights is enabled on the API in APIM Settings → Diagnostics |
| Claude can't connect | Verify the `url` is reachable and the subscription key is correct |
| Token audience mismatch | Ensure scope is `https://api.fabric.microsoft.com/.default` (not `.com/user_impersonation`) |
