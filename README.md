# Fabric MCP Data Agent — API Management Gateway

This project configures Azure API Management (APIM) as a secure gateway in front of a Microsoft Fabric Data Agent MCP endpoint. APIM handles:

- **OAuth Authorization Server facade** — MCP clients (VS Code, Claude Desktop) use standard OAuth discovery + PKCE flow; APIM proxies to Entra ID
- **Pre-authentication** — Validates Entra ID JWT tokens before forwarding to Fabric
- **Observability** — Log Analytics gateway logs, custom metrics, LLM message logging
- **Group-based access control** — Optional JWT claim filtering by security group

## Architecture

```
┌──────────────┐     ┌───────────────────────────┐     ┌─────────────────────────┐
│  MCP Client  │────▶│  Azure API Management     │────▶│  Fabric Data Agent MCP  │
│ (VS Code,    │     │  fabric-ai-demo-pcc       │     │  (Finance Agent)        │
│  Claude,     │     │                           │     │                         │
│  curl)       │     │  ┌─ /.well-known/oauth ─┐ │     │  Workspace: 3a074a45... │
└──────────────┘     │  │  /authorize (302→Entra)│ │     └─────────────────────────┘
       │             │  │  /token (proxy→Entra)  │ │
       │ OAuth PKCE  │  └────────────────────────┘ │
       │ + Bearer    │                             │
       │             │  Logs → App Insights        │
       │             │       → Log Analytics       │
       │             │  Custom Metrics (UPN-keyed) │
       └─────────────┴─────────────────────────────┘
```

## Endpoints

| Endpoint | URL | Auth Required |
|----------|-----|---------------|
| **MCP Gateway** | `https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp/` | Bearer token + subscription key |
| **OAuth Metadata** | `https://fabric-ai-demo-pcc.azure-api.net/.well-known/oauth-authorization-server` | None |
| **Authorize** | `https://fabric-ai-demo-pcc.azure-api.net/authorize` | None (redirects to Entra) |
| **Token** | `https://fabric-ai-demo-pcc.azure-api.net/token` | None (proxies to Entra) |
| **Direct Fabric** | `https://api.fabric.microsoft.com/v1/mcp/workspaces/3a074a45-be8c-4556-8866-bb3c81327a6b/dataagents/46e225d0-6029-4491-a943-76f6dc33ca1f/agent` | Bearer token |

## Prerequisites

- Azure CLI installed and signed in (`az login`)
- Access to the `onemtc.net` tenant (tenant ID: `d7d6e19e-5176-4dea-a576-1681f77e0243`)
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

The `.vscode/mcp.json` file connects VS Code's MCP client to the Fabric endpoint through APIM with interactive OAuth authentication:

```json
{
  "servers": {
    "Fabric Finance Agent MCP server": {
      "type": "http",
      "url": "https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp/",
      "oauth": {
        "clientId": "e5399261-3e94-4f88-b8f0-74cfff758e6d"
      }
    }
  }
}
```

When the MCP server starts, VS Code will:
1. Fetch `/.well-known/oauth-authorization-server` from the gateway to discover auth endpoints
2. Open a browser popup for interactive Entra ID login (Public Client + PKCE)
3. Exchange the auth code for a token via the `/token` endpoint
4. Attach the Bearer token to all MCP requests automatically

No manual token pasting required — VS Code handles the full OAuth lifecycle.

---

## 4. Claude Desktop Configuration

Claude Desktop supports remote MCP servers with OAuth authentication. APIM serves as the OAuth authorization server facade, redirecting to Entra ID for interactive login.

### Setup Steps

1. **In Claude Desktop:** Add a new MCP server connection
   - **Server URL:** `https://fabric-ai-demo-pcc.azure-api.net/fabric-mcp/`
   - **Client ID:** `e5399261-3e94-4f88-b8f0-74cfff758e6d`

2. **Click Connect** — Claude Desktop will:
   - Discover auth endpoints via `/.well-known/oauth-authorization-server`
   - Open your browser to Entra ID login (APIM `/authorize` → 302 to `login.microsoftonline.com`)
   - After sign-in, Entra redirects back to `https://claude.ai/api/mcp/auth_callback` with an auth code
   - Claude exchanges the code for a token via APIM `/token` (proxied to Entra)
   - All subsequent MCP requests include the Bearer token automatically

3. **Verify:** Ask Claude a question like _"Which product had the highest sales?"_ — it should invoke the Fabric Finance Agent tool

### Entra ID App Registration Requirements

The app registration (`e5399261-3e94-4f88-b8f0-74cfff758e6d`) must have:

| Setting | Value |
|---------|-------|
| Platform | Web |
| Redirect URI | `https://claude.ai/api/mcp/auth_callback` |
| Allow public client flows | Yes |
| API Permissions | `https://api.fabric.microsoft.com/user_impersonation` (delegated) |

### OAuth Flow Diagram

```
Claude Desktop                    APIM Gateway                     Entra ID
     │                                │                               │
     │─── GET /.well-known/oauth ────▶│                               │
     │◀── {authorize, token URLs} ────│                               │
     │                                │                               │
     │─── GET /authorize?... ────────▶│                               │
     │◀── 302 Redirect ──────────────│──── login.microsoftonline ───▶│
     │                                │                               │
     │◀── Browser login ─────────────────────────────────────────────│
     │─── (callback with code) ──────▶│                               │
     │                                │                               │
     │─── POST /token {code} ────────▶│─── POST /oauth2/v2.0/token ─▶│
     │◀── {access_token} ────────────│◀── {access_token} ───────────│
     │                                │                               │
     │─── POST /fabric-mcp/ ─────────▶│─── validate JWT ──────────────│
     │    (Bearer token)              │─── forward to Fabric ─────────│
     │◀── response ──────────────────│                               │
```

---

## 5. Observability & Logging

Requests through APIM are tracked via two mechanisms:

| Mechanism | What it captures | Where to query |
|-----------|-----------------|----------------|
| **Diagnostic Settings** (gateway logs) | URL, status code, latency, IP, UPN header, subscription | APIM → Monitoring → Logs |
| **Custom Metrics** (`emit-metric`) | Request/response/error counts by UPN | Azure Monitor → Metrics |

### Setup: Enable UPN in Gateway Logs

The policy extracts the caller's UPN from the JWT and sets it as a request header (`X-Caller-UPN`). To surface it in `ApiManagementGatewayLogs`, configure API Diagnostics to capture that header:

1. **APIM** → **APIs** → select `Fabric MCP Data Agent`
2. **Settings** tab → scroll to **Diagnostics Logs**
3. Click the **Azure Monitor** row (or add one)
4. Set **Sampling** → `100%`
5. Under **Frontend Request** → **Headers to log** → add: `X-Caller-UPN`
6. Click **Save**

After deploying the policy and sending a request (wait ~5 min for ingestion):

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| project TimeGenerated, ApimSubscriptionId, RequestHeaders, ResponseCode
| take 5
```

### KQL Queries

Run from: **APIM → Monitoring → Logs** (or the `onemtcww` workspace directly)

See [`kql.md`](kql.md) for the full query library. Quick reference:

```kql
// All traffic with UPN and subscription
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| project
    TimeGenerated,
    ApimSubscriptionId,
    CallerUPN = tostring(RequestHeaders["X-Caller-UPN"]),
    ResponseCode,
    BackendTime
| order by TimeGenerated desc
```

### Custom Metrics (Azure Monitor)

- **Namespace:** `Fabric MCP Agent`
- **Metrics:** `fabric-mcp-request`, `fabric-mcp-response`, `fabric-mcp-error`
- **Dimensions:** Caller UPN, Status Code, Error Reason

To view: APIM → **Monitoring → Metrics** → Namespace: `Fabric MCP Agent`

---

## Project Structure

```
fabric-pcc/
├── .vscode/
│   └── mcp.json                    # VS Code MCP server config (OAuth)
├── policies/
│   ├── fabric-mcp-inbound.xml      # APIM policy — MCP endpoint (token validation, routing, metrics)
│   ├── oauth-metadata.xml          # APIM policy — /.well-known/oauth-authorization-server
│   ├── oauth-authorize.xml         # APIM policy — /authorize (302 redirect to Entra)
│   └── oauth-token.xml             # APIM policy — /token (proxy to Entra token endpoint)
├── kql.md                          # KQL queries reference (gateway logs + LLM message logging)
└── README.md                       # This file
```

---

## 6. APIM OAuth Endpoint Setup

To enable interactive browser login for MCP clients (VS Code, Claude Desktop), APIM serves as an OAuth authorization server facade. Three endpoints are required on a **root-level API** (no URL suffix) with **subscription not required**.

### API Configuration

1. **Azure Portal → APIM → APIs → + Add API → HTTP**
   - Display name: `OAuth`
   - URL suffix: *(empty)*
   - Subscription required: **No**

2. **Add 3 operations:**

| Method | URL Path | Policy File | Purpose |
|--------|----------|-------------|---------|
| GET | `/.well-known/oauth-authorization-server` | `policies/oauth-metadata.xml` | Returns OAuth metadata (endpoints, scopes) |
| GET | `/authorize` | `policies/oauth-authorize.xml` | 302 redirects to Entra ID with full query string |
| POST | `/token` | `policies/oauth-token.xml` | Proxies token exchange to Entra ID |

3. **Important:** These operations must **not** inherit token validation from a parent policy. The policies omit `<base />` in inbound to prevent this.

### Verifying the Setup

```powershell
# Test metadata discovery
Invoke-RestMethod -Uri "https://fabric-ai-demo-pcc.azure-api.net/.well-known/oauth-authorization-server"

# Test authorize redirect (should return 302)
$r = Invoke-WebRequest -Uri "https://fabric-ai-demo-pcc.azure-api.net/authorize?response_type=code&client_id=e5399261-3e94-4f88-b8f0-74cfff758e6d&redirect_uri=https://claude.ai/api/mcp/auth_callback&code_challenge=test&code_challenge_method=S256&state=test" -MaximumRedirection 0 -ErrorAction SilentlyContinue -SkipHttpErrorCheck
$r.StatusCode  # Should be 302
$r.Headers['Location']  # Should start with https://login.microsoftonline.com/...
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `401 Unauthorized` from APIM | Token expired — VS Code/Claude should auto-refresh; for cURL regenerate with `az account get-access-token` |
| `401` with valid token | Check tenant ID in token matches `32dc2feb-...` (onemtc.net) |
| `403 Forbidden` from Fabric | Your user needs access to the Fabric workspace |
| No UPN in gateway logs | Ensure API Diagnostics has `X-Caller-UPN` in "Headers to log" (see §5) |
| No rows in `ApiManagementGatewayLogs` | Check Diagnostic Settings exist (APIM → Diagnostic settings) and wait ~5 min |
| VS Code MCP won't connect | Ensure `oauth` property (not `auth`) is set in `.vscode/mcp.json` |
| VS Code "metadata not found" | Ensure the `/.well-known/oauth-authorization-server` operation exists on a root-level API with empty URL suffix |
| Claude Desktop 401 on authorize/token | Ensure subscription is not required on the OAuth API |
| Token audience mismatch | Ensure scope is `https://api.fabric.microsoft.com/.default` (not `.com/user_impersonation`) |
| Double `??` in authorize URL | `context.Request.Url.QueryString` already includes `?` — do not prepend another |

---

## 7. Group-Based Access Filtering (Optional)

To restrict MCP access to specific security groups, add a `groups` claim check to the JWT validation policy. See [`policies/group-filtering-setup.md`](policies/group-filtering-setup.md) for the full setup guide covering:

- Configuring the app registration to emit group claims
- Adding `<required-claims>` to the inbound policy
- Testing with MSAL.PS token acquisition
