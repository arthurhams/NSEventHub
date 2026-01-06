# Azure Function Flex Consumption with VNet and Storage Account
# This script creates a VNet, Storage Account with VNet integration, and Azure Function in Flex Consumption mode

# Parameters
$subscriptionId = "763346f1-8c3e-4968-a752-83afba56900f"
$resourceGroupName = "rg-flexfunc-demo"
$location = "westeurope"

# Resource names
$vnetName = "vnet-flexfunc"
$subnetName = "subnet-flexfunc"
$storageAccountName = "stflexfunc$(Get-Random -Minimum 1000 -Maximum 9999)"
$functionAppName = "func-flex-$(Get-Random -Minimum 1000 -Maximum 9999)"
$appInsightsName = "ai-flexfunc"

# VNet configuration
$vnetAddressPrefix = "10.0.0.0/16"
$subnetAddressPrefix = "10.0.1.0/24"

# Set the subscription context
Write-Host "Setting subscription context..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId

# Create Resource Group
Write-Host "Creating resource group: $resourceGroupName" -ForegroundColor Cyan
$rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    New-AzResourceGroup -Name $resourceGroupName -Location $location
}

# Create VNet and Subnet
Write-Host "Creating VNet: $vnetName" -ForegroundColor Cyan
$subnet = New-AzVirtualNetworkSubnetConfig `
    -Name $subnetName `
    -AddressPrefix $subnetAddressPrefix `
    -ServiceEndpoint "Microsoft.Storage"

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
if (-not $vnet) {
    $vnet = New-AzVirtualNetwork `
        -Name $vnetName `
        -ResourceGroupName $resourceGroupName `
        -Location $location `
        -AddressPrefix $vnetAddressPrefix `
        -Subnet $subnet
} else {
    Write-Host "VNet already exists" -ForegroundColor Yellow
}

# Get the subnet
$subnetConfig = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet

# Create Storage Account
Write-Host "Creating storage account: $storageAccountName" -ForegroundColor Cyan
$storageAccount = New-AzStorageAccount `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName `
    -Location $location `
    -SkuName Standard_LRS `
    -Kind StorageV2 `
    -AllowBlobPublicAccess $false `
    -MinimumTlsVersion TLS1_2

# Configure Storage Account Network Rules to allow VNet access
Write-Host "Configuring storage account network rules..." -ForegroundColor Cyan
Update-AzStorageAccountNetworkRuleSet `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName `
    -DefaultAction Deny `
    -Bypass AzureServices

Add-AzStorageAccountNetworkRule `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName `
    -VirtualNetworkResourceId $subnetConfig.Id

# Create Application Insights
Write-Host "Creating Application Insights: $appInsightsName" -ForegroundColor Cyan
$appInsights = Get-AzApplicationInsights -ResourceGroupName $resourceGroupName -Name $appInsightsName -ErrorAction SilentlyContinue
if (-not $appInsights) {
    $workspace = New-AzOperationalInsightsWorkspace `
        -ResourceGroupName $resourceGroupName `
        -Name "law-flexfunc" `
        -Location $location
    
    $appInsights = New-AzApplicationInsights `
        -ResourceGroupName $resourceGroupName `
        -Name $appInsightsName `
        -Location $location `
        -WorkspaceResourceId $workspace.ResourceId
}

# Get Storage Account Connection String
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName)[0].Value
$storageConnectionString = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$storageAccountKey;EndpointSuffix=core.windows.net"

# Create Azure Function App in Flex Consumption mode
Write-Host "Creating Azure Function App in Flex Consumption mode: $functionAppName" -ForegroundColor Cyan

az functionapp create `
    --name $functionAppName `
    --resource-group $resourceGroupName `
    --storage-account $storageAccountName `
    --plan "Consumption" `
    --runtime "dotnet-isolated" `
    --runtime-version "8" `
    --functions-version "4" `
    --os-type "Linux" `
    --vnet $vnetName `
    --app-insights-key $appInsights.InstrumentationKey `
    --app-insights-name $appInsights.Name


# Create the Function App with Flex Consumption hosting
#$functionApp = New-AzFunctionApp `
#    -Name $functionAppName `
#    -ResourceGroupName $resourceGroupName `
#    -Location $location `
#    -StorageAccountName $storageAccountName `
#    -Runtime DotNetIsolated `
#    -RuntimeVersion 8 `
#    -FunctionsVersion 4 `
#    -OSType Linux `
#    -ApplicationInsightsKey $appInsights.InstrumentationKey `
#    -ApplicationInsightsName $appInsights.Name

# Configure VNet integration
Write-Host "Configuring VNet integration..." -ForegroundColor Cyan
$functionAppResource = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $functionAppName

# Add VNet integration
Add-AzWebAppAccessRestrictionRule `
    -ResourceGroupName $resourceGroupName `
    -WebAppName $functionAppName `
    -Name "VNetRule" `
    -Priority 100 `
    -Action Allow `
    -SubnetId $subnetConfig.Id

# Enable VNet route all
$propertiesObject = @{
    vnetRouteAllEnabled = $true
}

Set-AzResource `
    -ResourceGroupName $resourceGroupName `
    -ResourceType "Microsoft.Web/sites/config" `
    -ResourceName "$functionAppName/web" `
    -Properties $propertiesObject `
    -ApiVersion "2023-01-01" `
    -Force

# Configure subnet delegation for Azure Functions
Write-Host "Configuring subnet delegation..." -ForegroundColor Cyan
$delegation = New-AzDelegation `
    -Name "delegation" `
    -ServiceName "Microsoft.Web/serverFarms"

Set-AzVirtualNetworkSubnetConfig `
    -Name $subnetName `
    -VirtualNetwork $vnet `
    -AddressPrefix $subnetAddressPrefix `
    -Delegation $delegation `
    -ServiceEndpoint "Microsoft.Storage" | Set-AzVirtualNetwork

# Update Function App settings for Flex Consumption
Write-Host "Updating app settings..." -ForegroundColor Cyan
$appSettings = @{
    "AzureWebJobsStorage" = $storageConnectionString
    "FUNCTIONS_EXTENSION_VERSION" = "~4"
    "FUNCTIONS_WORKER_RUNTIME" = "dotnet-isolated"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = $appInsights.ConnectionString
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = $storageConnectionString
    "WEBSITE_CONTENTSHARE" = $functionAppName.ToLower()
}

Update-AzFunctionAppSetting `
    -Name $functionAppName `
    -ResourceGroupName $resourceGroupName `
    -AppSetting $appSettings `
    -Force

# Enable managed identity
Write-Host "Enabling managed identity..." -ForegroundColor Cyan
Set-AzWebApp -AssignIdentity $true -Name $functionAppName -ResourceGroupName $resourceGroupName

# Grant Storage Blob Data Owner role to the Function App's managed identity
$functionApp = Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $functionAppName
$principalId = $functionApp.Identity.PrincipalId

New-AzRoleAssignment `
    -ObjectId $principalId `
    -RoleDefinitionName "Storage Blob Data Owner" `
    -Scope $storageAccount.Id

Write-Host "`nDeployment complete!" -ForegroundColor Green
Write-Host "Resource Group: $resourceGroupName" -ForegroundColor Yellow
Write-Host "VNet: $vnetName" -ForegroundColor Yellow
Write-Host "Storage Account: $storageAccountName" -ForegroundColor Yellow
Write-Host "Function App: $functionAppName" -ForegroundColor Yellow
Write-Host "Function App URL: https://$functionAppName.azurewebsites.net" -ForegroundColor Yellow
