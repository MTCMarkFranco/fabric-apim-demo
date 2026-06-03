# Group-Based Access Filtering via JWT Policy

Filter access to the Fabric MCP endpoint based on the caller's Entra ID security group membership, enforced directly in the APIM inbound policy.

## Prerequisites

1. An Entra ID security group containing authorized users
2. The group's **Object ID** (found in Entra ID → Groups → your group → Overview)
3. A **public client app registration** for Claude Desktop (see below)

---

## Configuring Claude Desktop to Acquire the Right Token

Claude Desktop's MCP transport doesn't have built-in OAuth, so you need to acquire a token externally and supply it. Here's the end-to-end setup.

### Step A: Register a Public Client App in Entra ID

1. Go to **Entra ID → App Registrations → New registration**
2. Name: `Claude Desktop MCP Client` (or similar)
3. Supported account types: **Single tenant**
4. Redirect URI: select **Public client/native (mobile & desktop)** → `http://localhost`
5. Click **Register**

After creation:

6. Go to **API Permissions → Add a permission → APIs my organization uses**
7. Search for **Power BI Service** (this covers `https://api.fabric.microsoft.com`)
8. Select **Delegated permissions** → add `Datamart.ReadWrite.All` or the appropriate Fabric scope
9. Click **Grant admin consent** (or have an admin do this)
10. Go to **Authentication** → ensure **Allow public client flows** is set to **Yes** (enables device code flow)

Record the **Application (client) ID** and your **Tenant ID** (`d7d6e19e-5176-4dea-a576-1681f77e0243`).

### Step B: Acquire a Token via Device Code Flow

Create a helper script that obtains a token. Save as `get-fabric-token.ps1`:

```powershell
# Requires: Install-Module Az.Accounts (or use MSAL.PS)
param(
    [string]$TenantId = "d7d6e19e-5176-4dea-a576-1681f77e0243",
    [string]$ClientId = "YOUR-CLAUDE-CLIENT-APP-ID",
    [string]$Scope    = "https://api.fabric.microsoft.com/.default"
)

# Using MSAL.PS for device code flow
if (-not (Get-Module -ListAvailable MSAL.PS)) {
    Install-Module MSAL.PS -Scope CurrentUser -Force
}

$token = Get-MsalToken -ClientId $ClientId `
                        -TenantId $TenantId `
                        -Scopes $Scope `
                        -DeviceCode

# Output just the access token
$token.AccessToken
```

Run it once interactively — it will prompt you to open a browser and enter a code. After auth, MSAL caches the refresh token so subsequent calls are silent until the refresh token expires.

### Step C: Configure Claude Desktop MCP

In your `claude_desktop_config.json` (typically `%APPDATA%\Claude\claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "fabric-agent": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://YOUR-APIM-GATEWAY.azure-api.net/fabric-mcp/mcp"],
      "env": {
        "AUTHORIZATION": "Bearer <TOKEN>"
      }
    }
  }
}
```

Since tokens expire (~60-75 min), a better pattern is to use a wrapper script that refreshes the token at startup:

```json
{
  "mcpServers": {
    "fabric-agent": {
      "command": "pwsh",
      "args": ["-File", "C:/Projects/fabric-pcc/scripts/start-mcp.ps1"]
    }
  }
}
```

Where `start-mcp.ps1` acquires a fresh token and launches the MCP transport:

```powershell
$token = & "C:/Projects/fabric-pcc/scripts/get-fabric-token.ps1"

$env:AUTHORIZATION = "Bearer $token"
npx -y mcp-remote "https://YOUR-APIM-GATEWAY.azure-api.net/fabric-mcp/mcp" `
    --header "Authorization: Bearer $token"
```

### Step D: Add the User to the Security Group

The user who authenticates via device code must be a member of the Entra security group checked by the APIM policy. Otherwise they'll get a valid token but receive a `403 Forbidden`.

### Token Validation Summary

| Claim | Expected Value | Checked By |
|-------|---------------|------------|
| `aud` | `https://api.fabric.microsoft.com` | `validate-azure-ad-token` |
| `tid` | `d7d6e19e-5176-4dea-a576-1681f77e0243` | `validate-azure-ad-token` |
| `groups` | Contains your security group Object ID | `<choose>` policy block |
| `upn` | User's email | Extracted for logging |

---

## Step 1: Configure Group Claims in the App Registration

1. Go to **Entra ID → App Registrations → your app**
2. Navigate to **Token Configuration → Add groups claim**
3. Select **Security groups**
4. For the token type (Access), choose **Group ID** as the format
5. Save

This causes Entra to emit a `groups` claim in the access token containing the Object IDs of the user's security groups.

## Step 2: Add the Policy Check

After the `validate-azure-ad-token` element in your inbound policy, add a `<choose>` block that inspects the `groups` claim:

```xml
<!-- Require membership in the allowed security group -->
<choose>
    <when condition="@{
        var jwt = (Jwt)context.Variables[&quot;validated-jwt&quot;];
        var allowedGroupId = &quot;YOUR-SECURITY-GROUP-OBJECT-ID&quot;;
        var groups = jwt.Claims.GetValueOrDefault(&quot;groups&quot;, &quot;&quot;);
        return groups.Contains(allowedGroupId);
    }">
        <!-- Authorized — continue -->
    </when>
    <otherwise>
        <return-response>
            <set-status code="403" reason="Forbidden" />
            <set-body>{"error":"User is not a member of the required security group."}</set-body>
        </return-response>
    </otherwise>
</choose>
```

Replace `YOUR-SECURITY-GROUP-OBJECT-ID` with the actual Object ID of your security group.

## Step 3: Handle Token Overage (200+ Groups)

If a user is a member of more than 200 groups, Entra does **not** include the `groups` claim in the token. Instead it emits a `_claim_names` property indicating an overage. You have two options:

### Option A: Use app role assignments instead of group claims

1. In the App Registration, go to **App Roles → Create app role**
2. Assign the security group to that app role via **Enterprise Applications → your app → Users and groups → Add assignment**
3. Check the `roles` claim in the policy instead of `groups` — this is never subject to overage

### Option B: Call Microsoft Graph on overage

Add a conditional `send-request` to the Microsoft Graph `/me/memberOf` endpoint when the `groups` claim is missing. This adds latency and requires the APIM instance to have a managed identity with `GroupMember.Read.All` permissions.

**Recommendation:** Option A (app roles) is simpler and avoids the overage problem entirely.

## Multiple Allowed Groups

Store group IDs in an APIM **Named Value** (e.g., `allowed-group-ids` = `id1,id2,id3`) and split in the policy:

```xml
<when condition="@{
    var jwt = (Jwt)context.Variables[&quot;validated-jwt&quot;];
    var allowedIds = &quot;{{allowed-group-ids}}&quot;.Split(',');
    var groups = jwt.Claims.GetValueOrDefault(&quot;groups&quot;, &quot;&quot;);
    return allowedIds.Any(id => groups.Contains(id.Trim()));
}">
```

## Adding a Dimension to Metrics

To track authorized vs. denied requests in your custom metrics, add a dimension:

```xml
<dimension name="Authorized" value="@(context.Response != null ? "true" : "false")" />
```

## Testing

1. Get a token for a user **in** the group → expect 200
2. Get a token for a user **not in** the group → expect 403
3. Remove the user from the group, wait for token expiry, re-authenticate → expect 403
