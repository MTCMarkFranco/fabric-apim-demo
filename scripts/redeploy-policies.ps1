$RG = "rg-pcc-demo"
$SN = "pcc-apim"
$API = "FABRIC-MCP-API"
$policiesDir = Join-Path $PSScriptRoot "..\policies"
$apiVersion = "2024-05-01"

# Get subscription ID
$sub = az account show --query id -o tsv
$baseUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$SN/apis/$API/operations"

Write-Host "=== Redeploying all policies ===" -ForegroundColor Cyan

$operations = @(
    @{ id = "mcp-endpoint";    file = "fabric-mcp-inbound.xml" }
    @{ id = "oauth-metadata";  file = "oauth-metadata.xml" }
    @{ id = "oauth-authorize"; file = "oauth-authorize.xml" }
    @{ id = "oauth-token";     file = "oauth-token.xml" }
)

$i = 0
foreach ($op in $operations) {
    $i++
    Write-Host "$i/4 $($op.id) <- $($op.file)"
    
    $policyXml = Get-Content (Join-Path $policiesDir $op.file) -Raw
    $body = @{
        properties = @{
            format = "xml"
            value  = $policyXml
        }
    } | ConvertTo-Json -Depth 3

    $tempFile = [System.IO.Path]::GetTempFileName()
    $body | Out-File -FilePath $tempFile -Encoding utf8

    $uri = "$baseUri/$($op.id)/policies/policy?api-version=$apiVersion"
    az rest --method PUT --uri $uri --body "@$tempFile" --headers "Content-Type=application/json" 2>&1 | Out-Null
    
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK" -ForegroundColor Green
    } else {
        Write-Host "  FAILED (exit code $LASTEXITCODE)" -ForegroundColor Red
    }
}

Write-Host "=== All policies redeployed ===" -ForegroundColor Green
