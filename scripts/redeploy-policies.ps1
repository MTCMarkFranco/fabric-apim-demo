$RG = "rg-pcc-demo"
$SN = "pcc-apim"
$API = "FABRIC-MCP-API"
$policiesDir = Join-Path $PSScriptRoot "..\policies"
$apiVersion = "2024-05-01"

# Get subscription ID and an ARM access token (Invoke-RestMethod handles BOMs that az rest chokes on)
$sub = az account show --query id -o tsv
$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$headers = @{
    Authorization  = "Bearer $armToken"
    "Content-Type" = "application/json"
}
$baseUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SN/apis/$API/operations"

Write-Host "=== Redeploying all policies ===" -ForegroundColor Cyan

$operations = @(
    @{ id = "mcp-endpoint";              file = "fabric-mcp-inbound.xml" }
    @{ id = "mcp-endpoint-get";          file = "fabric-mcp-inbound.xml" }
    @{ id = "mcp-endpoint-delete";       file = "fabric-mcp-inbound.xml" }
    @{ id = "mcp-endpoint-noslash";        file = "fabric-mcp-inbound.xml" }
    @{ id = "mcp-endpoint-get-noslash";    file = "fabric-mcp-inbound.xml" }
    @{ id = "mcp-endpoint-delete-noslash"; file = "fabric-mcp-inbound.xml" }
    @{ id = "oauth-metadata";            file = "oauth-metadata.xml" }
    @{ id = "oauth-metadata-path";       file = "oauth-metadata.xml" }
    @{ id = "oauth-metadata-root";       file = "oauth-metadata.xml" }
    @{ id = "oauth-authorize";           file = "oauth-authorize.xml" }
    @{ id = "oauth-token";               file = "oauth-token.xml" }
    @{ id = "oauth-protected-resource";  file = "oauth-protected-resource.xml" }
    @{ id = "oauth-protected-resource-path"; file = "oauth-protected-resource.xml" }
)

$failures = 0
$i = 0
foreach ($op in $operations) {
    $i++
    Write-Host "$i/$($operations.Count) $($op.id) <- $($op.file)"

    $policyXml = Get-Content (Join-Path $policiesDir $op.file) -Raw
    $body = @{
        properties = @{
            format = "xml"
            value  = $policyXml
        }
    } | ConvertTo-Json -Depth 3

    $uri = "$baseUri/$($op.id)/policies/policy?api-version=$apiVersion"

    try {
        $response = Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $body -ErrorAction Stop
        if ($response.name -eq "policy") {
            Write-Host "  OK" -ForegroundColor Green
        } else {
            $failures++
            Write-Host "  FAILED — unexpected response:" -ForegroundColor Red
            Write-Host ($response | ConvertTo-Json -Depth 5) -ForegroundColor DarkRed
        }
    } catch {
        $failures++
        Write-Host "  FAILED" -ForegroundColor Red
        $errBody = $null
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $errBody = $reader.ReadToEnd()
            } catch {}
        }
        if ($errBody) {
            Write-Host $errBody -ForegroundColor DarkRed
        } else {
            Write-Host $_.Exception.Message -ForegroundColor DarkRed
        }
    }
}

if ($failures -eq 0) {
    Write-Host "=== All policies redeployed ===" -ForegroundColor Green
} else {
    Write-Host "=== $failures of $($operations.Count) policies failed ===" -ForegroundColor Red
    exit 1
}
