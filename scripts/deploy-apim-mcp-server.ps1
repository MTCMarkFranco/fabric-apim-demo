<#
.SYNOPSIS
    Deploys the Fabric MCP Data Agent as a properly-routed MCP Server in Azure API Management.

.DESCRIPTION
    Configures APIM operations so that:
    - POST /fabric-mcp/         → forwards to Fabric MCP backend (fabric-mcp-inbound policy)
    - GET  /fabric-mcp/.well-known/oauth-authorization-server → returns OAuth metadata
    - GET  /fabric-mcp/authorize → redirects to Entra ID
    - POST /fabric-mcp/token    → proxies token exchange to Entra ID

    This fixes the routing conflict where POST to the MCP endpoint was returning
    OAuth metadata instead of forwarding to the Fabric Data Agent.

    IMPORTANT: Requires "API Management Service Contributor" or higher RBAC role on
    the APIM instance. If running under a user without this role, use the Azure Portal
    instructions below instead.

.PARAMETER ResourceGroup
    The APIM resource group name.

.PARAMETER ServiceName
    The APIM service name.

.PARAMETER ApiId
    The API identifier in APIM.

.NOTES
    === PORTAL FIX (if you lack CLI RBAC access) ===

    The root cause is that the existing API at /fabric-mcp has a catch-all operation
    (or API-level policy) that returns OAuth metadata for ALL requests, including POST.

    To fix in the Azure Portal:
    1. Go to APIM → fabric-ai-demo-pcc → APIs → select the API at path "fabric-mcp"
    2. Check "All operations" policy — if oauth-metadata.xml is applied at API level,
       REMOVE it from there (it should only be on the specific GET operation)
    3. Ensure these SEPARATE operations exist:
       - POST /         display name "MCP Endpoint"         policy: fabric-mcp-inbound.xml
       - GET  /.well-known/oauth-authorization-server       policy: oauth-metadata.xml
       - GET  /authorize                                    policy: oauth-authorize.xml
       - POST /token                                        policy: oauth-token.xml
    4. On the "MCP Endpoint" (POST /) operation, apply the fabric-mcp-inbound.xml policy
    5. Test: POST to /fabric-mcp/ with a valid Bearer token should return MCP serverInfo,
       NOT OAuth metadata JSON

.EXAMPLE
    .\deploy-apim-mcp-server.ps1 -ResourceGroup "rg-fabric-ai-demo" -ServiceName "fabric-ai-demo-pcc" -ApiId "fabric-mcp-data-agent"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "rg-pcc-demo",

    [Parameter(Mandatory = $false)]
    [string]$ServiceName = "pcc-apim",

    [Parameter(Mandatory = $false)]
    [string]$ApiId = "FABRIC-MCP-API"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Fabric MCP Server — APIM Deployment ===" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------------------
# 1. Deploy App Registration (Entra ID)
# -------------------------------------------------------------------
Write-Host "[1/7] Deploying Entra ID App Registration..." -ForegroundColor Yellow

$AppDisplayName = "Fabric Finance Agent MCP server"
$AppId = "e5399261-3e94-4f88-b8f0-74cfff758e6d"
$TenantId = "d7d6e19e-5176-4dea-a576-1681f77e0243"

# Check if app already exists
$existingApp = az ad app show --id $AppId --query "appId" -o tsv 2>$null

if ($existingApp) {
    Write-Host "  App registration exists (appId: $AppId). Updating..." -ForegroundColor Gray

    # Update redirect URIs (web platform)
    az ad app update --id $AppId `
        --web-redirect-uris `
            "https://claude.ai/api/mcp/auth_callback" `
            "https://vscode.dev/redirect" `
            "https://127.0.0.1:33418" `
            "http://127.0.0.1:33418/" `
            "http://localhost:33418/"

    # Enable implicit grant (access + ID tokens)
    az ad app update --id $AppId `
        --enable-access-token-issuance true `
        --enable-id-token-issuance true

    # Enable public client flows (isFallbackPublicClient = true)
    az ad app update --id $AppId `
        --is-fallback-public-client true

    # Set sign-in audience to single tenant
    az ad app update --id $AppId `
        --sign-in-audience AzureADMyOrg

    Write-Host "  Updated redirect URIs, implicit grant, and public client settings." -ForegroundColor Green
} else {
    Write-Host "  App registration not found. Creating..." -ForegroundColor Gray

    # Create the app registration
    az ad app create `
        --display-name $AppDisplayName `
        --sign-in-audience AzureADMyOrg `
        --is-fallback-public-client true `
        --web-redirect-uris `
            "https://claude.ai/api/mcp/auth_callback" `
            "https://vscode.dev/redirect" `
            "https://127.0.0.1:33418" `
            "http://127.0.0.1:33418/" `
            "http://localhost:33418/" `
        --enable-access-token-issuance true `
        --enable-id-token-issuance true

    # Get the newly created app's object ID
    $newApp = az ad app list --display-name $AppDisplayName --query "[0].{objectId:id, appId:appId}" -o json | ConvertFrom-Json
    Write-Host "  Created app: $($newApp.appId) (object: $($newApp.objectId))" -ForegroundColor Green

    # Update AppId variable for downstream use
    $AppId = $newApp.appId
}

# Configure required API permissions:
#   - Power BI Service / Fabric (00000009-0000-0000-c000-000000000000) → user_impersonation (91f75836-b68c-4fff-84db-4372412a2c82)
#   - Microsoft Graph (00000003-0000-0000-c000-000000000000) → User.Read (e1fe6dd8-ba31-4d61-89e7-88639da4683d)
Write-Host "  Setting API permissions (Fabric user_impersonation + Graph User.Read)..."

$requiredResourceAccess = @(
    @{
        resourceAppId = "00000009-0000-0000-c000-000000000000"
        resourceAccess = @(
            @{ id = "91f75836-b68c-4fff-84db-4372412a2c82"; type = "Scope" }
        )
    }
    @{
        resourceAppId = "00000003-0000-0000-c000-000000000000"
        resourceAccess = @(
            @{ id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"; type = "Scope" }
        )
    }
) | ConvertTo-Json -Depth 4

# Write to temp file to avoid PowerShell JSON quoting issues with az cli
$tempFile = [System.IO.Path]::GetTempFileName()
$requiredResourceAccess | Out-File -FilePath $tempFile -Encoding utf8
az ad app update --id $AppId --required-resource-accesses "@$tempFile"
Remove-Item $tempFile -ErrorAction SilentlyContinue

Write-Host "  App registration deployed successfully." -ForegroundColor Green
Write-Host "  App ID: $AppId" -ForegroundColor White
Write-Host "  Redirect URIs: https://claude.ai/api/mcp/auth_callback, https://vscode.dev/redirect, https://127.0.0.1:33418" -ForegroundColor White
Write-Host ""

# -------------------------------------------------------------------
# 2. Verify Azure CLI context
# -------------------------------------------------------------------
Write-Host "[2/7] Verifying Azure CLI context..." -ForegroundColor Yellow
$account = az account show --query "{name:name, id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in. Run: az login --tenant onemtc.net --allow-no-subscriptions"
    exit 1
}
Write-Host "  Subscription: $($account.name) ($($account.id))"
Write-Host "  Tenant: $($account.tenantId)"
Write-Host ""

# -------------------------------------------------------------------
# 3. Create or update the API with correct path prefix
# -------------------------------------------------------------------
Write-Host "[3/8] Creating/updating API '$ApiId' with root path (operations prefixed with /fabric-mcp/)..." -ForegroundColor Yellow

az apim api create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --display-name "Fabric MCP Data Agent" `
    --path "" `
    --protocols https `
    --subscription-required false

# Wait for API to be ready
Start-Sleep -Seconds 3
Write-Host "  Done." -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------
# 4. Create operations with correct HTTP method + URL matching
# -------------------------------------------------------------------
Write-Host "[4/8] Creating API operations..." -ForegroundColor Yellow

# Operation 1: MCP Endpoint (POST /fabric-mcp/)
# This is the main MCP JSON-RPC endpoint
Write-Host "  Creating: POST /fabric-mcp/ (MCP Endpoint)..."
az apim api operation create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "mcp-endpoint" `
    --display-name "MCP Endpoint" `
    --method POST `
    --url-template "/fabric-mcp/" `
    2>$null

# Operation 2: OAuth Metadata (GET /fabric-mcp/.well-known/oauth-authorization-server)
Write-Host "  Creating: GET /fabric-mcp/.well-known/oauth-authorization-server (OAuth Metadata)..."
az apim api operation create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-metadata" `
    --display-name "OAuth Authorization Server Metadata" `
    --method GET `
    --url-template "/fabric-mcp/.well-known/oauth-authorization-server" `
    2>$null

# Operation 3: Authorize (GET /fabric-mcp/authorize)
Write-Host "  Creating: GET /fabric-mcp/authorize (OAuth Authorize)..."
az apim api operation create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-authorize" `
    --display-name "OAuth Authorize" `
    --method GET `
    --url-template "/fabric-mcp/authorize" `
    2>$null

# Operation 4: Token (POST /fabric-mcp/token)
Write-Host "  Creating: POST /fabric-mcp/token (OAuth Token)..."
az apim api operation create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-token" `
    --display-name "OAuth Token" `
    --method POST `
    --url-template "/fabric-mcp/token" `
    2>$null

# Operation 5: Protected Resource Metadata (GET /.well-known/oauth-protected-resource)
# RFC 9728 — MCP clients discover auth server from this origin-level endpoint
Write-Host "  Creating: GET /.well-known/oauth-protected-resource (RFC 9728 Discovery)..."
az apim api operation create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-protected-resource" `
    --display-name "Protected Resource Metadata" `
    --method GET `
    --url-template "/.well-known/oauth-protected-resource" `
    2>$null

Write-Host "  All operations created." -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------
# 5. Apply operation-level policies
# -------------------------------------------------------------------
Write-Host "[5/8] Applying operation-level policies..." -ForegroundColor Yellow

$policiesDir = Join-Path $PSScriptRoot "..\policies"

# MCP Endpoint policy (POST /) — forward to Fabric
$mcpPolicy = Get-Content (Join-Path $policiesDir "fabric-mcp-inbound.xml") -Raw
Write-Host "  Applying: mcp-endpoint ← fabric-mcp-inbound.xml"
az apim api operation policy create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "mcp-endpoint" `
    --policy-format xml `
    --value $mcpPolicy `
    2>$null

# OAuth Metadata policy (GET /.well-known/...)
$metadataPolicy = Get-Content (Join-Path $policiesDir "oauth-metadata.xml") -Raw
Write-Host "  Applying: oauth-metadata ← oauth-metadata.xml"
az apim api operation policy create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-metadata" `
    --policy-format xml `
    --value $metadataPolicy `
    2>$null

# OAuth Authorize policy (GET /authorize)
$authorizePolicy = Get-Content (Join-Path $policiesDir "oauth-authorize.xml") -Raw
Write-Host "  Applying: oauth-authorize ← oauth-authorize.xml"
az apim api operation policy create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-authorize" `
    --policy-format xml `
    --value $authorizePolicy `
    2>$null

# OAuth Token policy (POST /fabric-mcp/token)
$tokenPolicy = Get-Content (Join-Path $policiesDir "oauth-token.xml") -Raw
Write-Host "  Applying: oauth-token ← oauth-token.xml"
az apim api operation policy create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-token" `
    --policy-format xml `
    --value $tokenPolicy `
    2>$null

# Protected Resource Metadata policy (GET /.well-known/oauth-protected-resource)
$protectedResourcePolicy = Get-Content (Join-Path $policiesDir "oauth-protected-resource.xml") -Raw
Write-Host "  Applying: oauth-protected-resource ← oauth-protected-resource.xml"
az apim api operation policy create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-protected-resource" `
    --policy-format xml `
    --value $protectedResourcePolicy `
    2>$null

Write-Host "  All policies applied." -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------
# 6. Update OAuth metadata to use relative paths under /fabric-mcp/
# -------------------------------------------------------------------
Write-Host "[6/8] Updating OAuth metadata to use MCP-relative paths..." -ForegroundColor Yellow

# The OAuth metadata must point clients to /fabric-mcp/authorize and /fabric-mcp/token
# so the full OAuth flow stays within the MCP server's URL namespace.
$updatedMetadataPolicy = @'
<policies>
    <inbound>
        <!-- No <base /> — this endpoint must be unauthenticated -->
        <return-response>
            <set-status code="200" reason="OK" />
            <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
            </set-header>
            <set-body>{
  "issuer": "https://login.microsoftonline.com/d7d6e19e-5176-4dea-a576-1681f77e0243/v2.0",
  "authorization_endpoint": "https://pcc-apim.azure-api.net/fabric-mcp/authorize",
  "token_endpoint": "https://pcc-apim.azure-api.net/fabric-mcp/token",
  "scopes_supported": ["https://api.fabric.microsoft.com/.default", "openid", "profile", "offline_access"],
  "response_types_supported": ["code"],
  "response_modes_supported": ["query"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "token_endpoint_auth_methods_supported": ["none"],
  "code_challenge_methods_supported": ["S256"]
}</set-body>
        </return-response>
    </inbound>
    <backend>
        <base />
    </backend>
    <outbound>
        <base />
    </outbound>
    <on-error>
        <base />
    </on-error>
</policies>
'@

az apim api operation policy create `
    --resource-group $ResourceGroup `
    --service-name $ServiceName `
    --api-id $ApiId `
    --operation-id "oauth-metadata" `
    --policy-format xml `
    --value $updatedMetadataPolicy `
    2>$null

Write-Host "  OAuth metadata updated with /fabric-mcp/authorize and /fabric-mcp/token paths." -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------
# 7. Verify routing
# -------------------------------------------------------------------
Write-Host "[7/8] Verifying endpoint routing..." -ForegroundColor Yellow

# Test OAuth metadata
Write-Host "  Testing GET /fabric-mcp/.well-known/oauth-authorization-server..."
try {
    $metaResp = Invoke-RestMethod -Uri "https://$ServiceName.azure-api.net/fabric-mcp/.well-known/oauth-authorization-server" -Method GET -TimeoutSec 10
    if ($metaResp.authorization_endpoint -like "*fabric-mcp/authorize*") {
        Write-Host "    ✓ OAuth metadata returns correct authorize endpoint" -ForegroundColor Green
    } else {
        Write-Host "    ⚠ OAuth metadata returned but authorize endpoint may be wrong" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Test MCP endpoint (requires auth)
Write-Host "  Testing POST /fabric-mcp/ (MCP initialize)..."
try {
    $token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    $initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"deploy-test","version":"1.0"}}}'
    $mcpResp = Invoke-RestMethod -Uri "https://$ServiceName.azure-api.net/fabric-mcp/" -Method POST `
        -Headers @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $initBody -TimeoutSec 30
    if ($mcpResp.result.serverInfo.name) {
        Write-Host "    ✓ MCP server responded: $($mcpResp.result.serverInfo.name) v$($mcpResp.result.serverInfo.version)" -ForegroundColor Green
    } else {
        Write-Host "    ⚠ Got response but no serverInfo — check policy routing" -ForegroundColor Yellow
        Write-Host "    Response: $($mcpResp | ConvertTo-Json -Depth 3)"
    }
} catch {
    Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    This may indicate the inbound policy is still misconfigured."
}

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "MCP Server URL: https://$ServiceName.azure-api.net/fabric-mcp/" -ForegroundColor White
Write-Host ""
Write-Host "Operations configured:" -ForegroundColor White
Write-Host "  POST /fabric-mcp/                                      → Fabric Data Agent MCP backend"
Write-Host "  GET  /fabric-mcp/.well-known/oauth-authorization-server → OAuth metadata"
Write-Host "  GET  /fabric-mcp/authorize                             → 302 redirect to Entra ID"
Write-Host "  POST /fabric-mcp/token                                 → Proxy to Entra ID token endpoint"
Write-Host "  GET  /.well-known/oauth-protected-resource             → RFC 9728 discovery"
Write-Host ""
Write-Host "VS Code mcp.json config:" -ForegroundColor White
Write-Host '  { "type": "http", "url": "https://pcc-apim.azure-api.net/fabric-mcp/", "oauth": { "clientId": "e5399261-3e94-4f88-b8f0-74cfff758e6d" } }'
