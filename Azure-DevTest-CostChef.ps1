#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    🍳 CloudCostChefs Dev/Test Resource Cost Chef – Azure Edition

.DESCRIPTION
    This PowerShell recipe scans your Azure subscription for resources tagged as dev/test
    and serves up a multi-course report highlighting cost optimizations:
      • PaaS services running premium SKUs (time to downgrade!)  
      • VMs missing stop/start automation tags (idle VM bills lurking)  
      • Oversized VMs in your dev/test kitchens  
      • Orphaned disks gathering dust  
      • Unused Public IPs quietly simmering cost  
      • Resource groups missing “use-by” or expired tags  
      • Overly permissive NSGs (open-door policies)  

    Outputs:
      • CSV files for each issue category  
      • A CloudCostChefs–styled HTML report you can plate and share  

.PARAMETER SubscriptionId
    (String) Optional Azure subscription ID; defaults to current context if omitted.

.PARAMETER OutputPath
    (String) Folder path for CSV & HTML reports (default: current directory).

.PARAMETER DevTestTags
    (String[]) Tag values to recognize dev/test resources
    (default: 'dev','test','development','testing','staging','qa').

.PARAMETER SuppressWarnings
    (Bool) Silently suppress Azure PowerShell breaking change warnings
    for a clean console output (default: $true).

.EXAMPLE
    # Quick audit with defaults:
    .\DevTest-CostChef.ps1

.EXAMPLE
    # Target specific subscription:
    .\DevTest-CostChef.ps1 -SubscriptionId "1234-5678-90ab-cdef-1234567890ab" -OutputPath "C:\Reports"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory=$false)]
    [string[]]$DevTestTags = @('dev', 'test', 'development', 'testing', 'staging', 'qa'),
    
    [Parameter(Mandatory=$false)]
    [bool]$SuppressWarnings = $true
)

# — Silence PS warnings for clutter-free cooking —
if ($SuppressWarnings) {
    $WarningPreference = 'SilentlyContinue'
    $env:SuppressAzurePowerShellBreakingChangeWarnings = "true"
}

# — Ensure Az modules are available —
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "❌ Az.Accounts is required. Install with: Install-Module Az -Scope CurrentUser"
    exit 1
}

# Connect to Azure if not already connected
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "🔑 Signing into Azure..." -ForegroundColor Yellow
        Connect-AzAccount
    }
    
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId
    }
    
    $currentContext = Get-AzContext
    Write-Host "🍽️ Using Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" -ForegroundColor Green
}
catch {
    Write-Error "❌ Failed Azure authentication: $($_.Exception.Message)"
    exit 1
}

# — Ingredient lists —
$PaaSResourceTypes = @{
    'Microsoft.Web/sites' = @('P1V2', 'P2V2', 'P3V2', 'P1V3', 'P2V3', 'P3V3', 'Premium')
    'Microsoft.Sql/servers/databases' = @('Premium', 'P1', 'P2', 'P4', 'P6', 'P11', 'P15')
    'Microsoft.Cache/Redis' = @('Premium')
    'Microsoft.Storage/storageAccounts' = @('Premium_LRS', 'Premium_ZRS')
    'Microsoft.DocumentDB/databaseAccounts' = @('Premium')
    'Microsoft.ServiceBus/namespaces' = @('Premium')
    'Microsoft.EventHub/namespaces' = @('Premium')
}

# Define oversized VM SKUs for dev/test environments
$OversizedVMSkUs = @(
    'Standard_D8s_v3', 'Standard_D16s_v3', 'Standard_D32s_v3', 'Standard_D64s_v3',
    'Standard_F8s_v2', 'Standard_F16s_v2', 'Standard_F32s_v2', 'Standard_F64s_v2',
    'Standard_E8s_v3', 'Standard_E16s_v3', 'Standard_E32s_v3', 'Standard_E64s_v3',
    'Standard_DS13', 'Standard_DS14', 'Standard_GS3', 'Standard_GS4', 'Standard_GS5'
)

# Define resource types that should have expiration tags (at resource group level)
$ExpirationTagNames = @('ExpirationDate', 'ExpireOn', 'TTL', 'DeleteAfter', 'ExpiresOn', 'ProjectEnd')


# — Prepare result bowls —
$PaaSPremiumResults = @()
$VMResults = @()
$OversizedVMResults = @()
$OrphanedDiskResults = @()
$ExpiredResourceResults = @()
$PublicIPResults = @()
$SecurityGroupResults = @()

Write-Host "Scanning resources..." -ForegroundColor Yellow

# — Gather and filter resources by dev/test tags —
$allResources = Get-AzResource
$devTestResources = $allResources | Where-Object {
    $resource = $_
    $hasDevTestTag = $false
    
    if ($resource.Tags) {
        foreach ($tagKey in $resource.Tags.Keys) {
            $tagValue = $resource.Tags[$tagKey].ToLower()
            if ($DevTestTags -contains $tagValue) {
                $hasDevTestTag = $true
                break
            }
        }
    }
    return $hasDevTestTag
}

Write-Host "🧂 Found $($devTestResources.Count) dev/test–tagged resources" -ForegroundColor Green

# Identify dev/test resource groups for orphaned resource checking
$devTestResourceGroups = $devTestResources | Select-Object -ExpandProperty ResourceGroupName | Sort-Object -Unique

# Check for orphaned disks
try {
    $allDisks = Get-AzDisk -ErrorAction SilentlyContinue
    $orphanedDisks = $allDisks | Where-Object { 
        -not $_.ManagedBy -and $_.ResourceGroupName -in $devTestResourceGroups 
    }

    foreach ($disk in $orphanedDisks) {
        $OrphanedDiskResults += [PSCustomObject]@{
            DiskName = $disk.Name
            ResourceGroup = $disk.ResourceGroupName
            Location = $disk.Location
            SizeGB = $disk.DiskSizeGB
            SkuName = $disk.Sku.Name
            CreatedDate = $disk.TimeCreated
            ResourceId = $disk.Id
        }
    }
}
catch {
    Write-Warning "Could not retrieve disk information: $($_.Exception.Message)"
}

# Check for public IPs not attached to anything
try {
    $allPublicIPs = Get-AzPublicIpAddress -ErrorAction SilentlyContinue
    $unusedPublicIPs = $allPublicIPs | Where-Object { 
        -not $_.IpConfiguration -and $_.ResourceGroupName -in $devTestResourceGroups 
    }

    foreach ($pip in $unusedPublicIPs) {
        $PublicIPResults += [PSCustomObject]@{
            PublicIPName = $pip.Name
            ResourceGroup = $pip.ResourceGroupName
            Location = $pip.Location
            IPAddress = $pip.IpAddress
            AllocationMethod = $pip.PublicIpAllocationMethod
            SkuName = $pip.Sku.Name
            ResourceId = $pip.Id
        }
    }
}
catch {
    Write-Warning "Could not retrieve public IP information: $($_.Exception.Message)"
}

# Check for overly permissive network security groups
try {
    $allNSGs = Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue | Where-Object { $_.ResourceGroupName -in $devTestResourceGroups }
    foreach ($nsg in $allNSGs) {
        $permissiveRules = $nsg.SecurityRules | Where-Object { 
            $_.Access -eq 'Allow' -and 
            $_.Direction -eq 'Inbound' -and 
            ($_.SourceAddressPrefix -eq '*' -or $_.SourceAddressPrefix -eq '0.0.0.0/0') -and
            ($_.DestinationPortRange -eq '*' -or $_.DestinationPortRange -contains '22' -or $_.DestinationPortRange -contains '3389')
        }
        
        if ($permissiveRules.Count -gt 0) {
            $SecurityGroupResults += [PSCustomObject]@{
                NSGName = $nsg.Name
                ResourceGroup = $nsg.ResourceGroupName
                Location = $nsg.Location
                PermissiveRulesCount = $permissiveRules.Count
                RuleNames = ($permissiveRules | Select-Object -ExpandProperty Name) -join ', '
                ResourceId = $nsg.Id
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve network security group information: $($_.Exception.Message)"
}

# Check PaaS services for premium SKUs
foreach ($resource in $devTestResources) {
    if ($PaaSResourceTypes.ContainsKey($resource.ResourceType)) {
        try {
            $resourceDetail = Get-AzResource -ResourceId $resource.ResourceId
            $sku = $null
            
            # Get SKU information based on resource type
            switch ($resource.ResourceType) {
                'Microsoft.Web/sites' {
                    try {
                        $webApp = Get-AzWebApp -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -ErrorAction SilentlyContinue
                        if ($webApp -and $webApp.AppServicePlan) {
                            # Get the App Service Plan details
                            $appServicePlan = Get-AzAppServicePlan -ResourceGroupName $webApp.ResourceGroup -Name $webApp.ServerFarmId.Split('/')[-1] -ErrorAction SilentlyContinue
                            if ($appServicePlan) {
                                $sku = $appServicePlan.Sku.Name
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not retrieve App Service details for $($resource.Name): $($_.Exception.Message)"
                    }
                }
                'Microsoft.Sql/servers/databases' {
                    try {
                        # Parse server and database names from resource name
                        $resourceParts = $resource.Name.Split('/')
                        if ($resourceParts.Count -ge 2) {
                            $serverName = $resourceParts[0]
                            $databaseName = $resourceParts[1]
                            $database = Get-AzSqlDatabase -ResourceGroupName $resource.ResourceGroupName -ServerName $serverName -DatabaseName $databaseName -ErrorAction SilentlyContinue
                            if ($database) {
                                $sku = $database.SkuName
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not retrieve SQL Database details for $($resource.Name): $($_.Exception.Message)"
                    }
                }
                'Microsoft.Cache/Redis' {
                    try {
                        $redis = Get-AzRedisCache -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -ErrorAction SilentlyContinue
                        if ($redis) {
                            $sku = $redis.Sku
                        }
                    }
                    catch {
                        Write-Verbose "Could not retrieve Redis Cache details for $($resource.Name): $($_.Exception.Message)"
                    }
                }
                default {
                    try {
                        if ($resourceDetail.Properties.sku) {
                            $sku = $resourceDetail.Properties.sku.name
                        } elseif ($resourceDetail.Sku) {
                            $sku = $resourceDetail.Sku.Name
                        }
                    }
                    catch {
                        Write-Verbose "Could not retrieve SKU details for $($resource.Name): $($_.Exception.Message)"
                    }
                }
            }
            
            # Check if SKU is premium
            $premiumSkus = $PaaSResourceTypes[$resource.ResourceType]
            if ($sku -and ($premiumSkus | Where-Object { $sku -like "*$_*" })) {
                $PaaSPremiumResults += [PSCustomObject]@{
                    ResourceName = $resource.Name
                    ResourceType = $resource.ResourceType
                    ResourceGroup = $resource.ResourceGroupName
                    Location = $resource.Location
                    CurrentSKU = $sku
                    Tags = ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                    ResourceId = $resource.ResourceId
                }
            }
        }
        catch {
            Write-Warning "Could not retrieve SKU information for $($resource.Name): $($_.Exception.Message)"
        }
    }
}

# Check VMs for stop/start tags and oversized instances
$vmResources = $devTestResources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/virtualMachines' }

foreach ($vm in $vmResources) {
    $hasStopStartTag = $false
    $stopStartTags = @('AutoShutdown', 'AutoStart', 'Schedule', 'StopStart', 'Automation')
    
    if ($vm.Tags) {
        foreach ($tagKey in $vm.Tags.Keys) {
            if ($stopStartTags | Where-Object { $tagKey -like "*$_*" }) {
                $hasStopStartTag = $true
                break
            }
        }
    }
    
    try {
        $vmDetail = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
        $powerState = ($vmDetail.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        $vmSize = $vmDetail.HardwareProfile.VmSize
        
        # Check for missing stop/start tags
        if (-not $hasStopStartTag) {
            $VMResults += [PSCustomObject]@{
                VMName = $vm.Name
                ResourceGroup = $vm.ResourceGroupName
                Location = $vm.Location
                PowerState = $powerState
                HasStopStartTag = $hasStopStartTag
                Tags = ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                VMSize = $vmSize
                ResourceId = $vm.ResourceId
            }
        }
        
        # Check for oversized VMs
        if ($OversizedVMSkUs -contains $vmSize) {
            $OversizedVMResults += [PSCustomObject]@{
                VMName = $vm.Name
                ResourceGroup = $vm.ResourceGroupName
                Location = $vm.Location
                CurrentSize = $vmSize
                PowerState = $powerState
                Tags = ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                ResourceId = $vm.ResourceId
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve VM details for $($vm.Name): $($_.Exception.Message)"
    }
}

# Check for resource groups with expiration dates
$devTestResourceGroups = $devTestResources | Select-Object -ExpandProperty ResourceGroupName | Sort-Object -Unique

foreach ($rgName in $devTestResourceGroups) {
    try {
        $resourceGroup = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
        if ($resourceGroup) {
            $hasExpirationTag = $false
            $expirationDate = $null
            $isExpired = $false
            $expirationTagName = $null
            
            if ($resourceGroup.Tags) {
                foreach ($tagKey in $resourceGroup.Tags.Keys) {
                    if ($ExpirationTagNames | Where-Object { $tagKey -like "*$_*" }) {
                        $hasExpirationTag = $true
                        $expirationDate = $resourceGroup.Tags[$tagKey]
                        $expirationTagName = $tagKey
                        
                        # Try to parse the date and check if expired
                        try {
                            $expDate = [DateTime]::Parse($expirationDate)
                            $isExpired = $expDate -lt (Get-Date)
                        }
                        catch {
                            # If date parsing fails, just note that there's an expiration tag
                        }
                        break
                    }
                }
            }
            
            # Report resource groups missing expiration tags OR those that are expired
            if (-not $hasExpirationTag -or $isExpired) {
                $resourceCount = ($devTestResources | Where-Object { $_.ResourceGroupName -eq $rgName }).Count
                
                $ExpiredResourceResults += [PSCustomObject]@{
                    ResourceGroupName = $rgName
                    Location = $resourceGroup.Location
                    HasExpirationTag = $hasExpirationTag
                    ExpirationTagName = $expirationTagName
                    ExpirationDate = $expirationDate
                    IsExpired = $isExpired
                    ResourceCount = $resourceCount
                    CreatedDate = $resourceGroup.CreatedTime
                    Tags = ($resourceGroup.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
                    ResourceGroupId = $resourceGroup.ResourceId
                }
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve resource group details for $($rgName): $($_.Exception.Message)"
    }
}

# — Reports: CSV & HTML —
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
Write-Host "Generating reports..." -ForegroundColor Yellow

$reportTypes = @(
    @{ Data = $PaaSPremiumResults; Name = "PaaS_Premium_SKUs" },
    @{ Data = $VMResults; Name = "VMs_Missing_StopStart_Tags" },
    @{ Data = $OversizedVMResults; Name = "Oversized_VMs" },
    @{ Data = $OrphanedDiskResults; Name = "Orphaned_Disks" },
    @{ Data = $ExpiredResourceResults; Name = "ResourceGroups_Missing_Expiration" },
    @{ Data = $PublicIPResults; Name = "Unused_Public_IPs" },
    @{ Data = $SecurityGroupResults; Name = "Permissive_Security_Groups" }
)

foreach ($report in $reportTypes) {
    if ($report.Data.Count -gt 0) {
        $csvPath = Join-Path $OutputPath "$($report.Name)_$timestamp.csv"
        $report.Data | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "$($report.Name) CSV report saved to: $csvPath" -ForegroundColor Green
    }
}

# — HTML plating —
$htmlPath = Join-Path $OutputPath "Azure_DevTest_Resource_Report_$timestamp.html"

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Dev/Test Resource Cost Chef Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1, h2 { color: #0078d4; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 30px; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #f2f2f2; font-weight: bold; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .summary { background-color: #e6f3ff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .warning { color: #d83b01; font-weight: bold; }
        .timestamp { color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>Dev/Test Resource Cost Chef Report</h1>
    <div class="timestamp">Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div>
    <div class='subtitle'>Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))</div>
    <div class='summary'>
      <p>🔍 Total scanned: <strong>$($devTestResources.Count)</strong></p>
      <p>☕ Premium SKUs: <strong>$($PaaSPremiumResults.Count)</strong></p>
      <p>🚦 VMs missing auto-tags: <strong>$($VMResults.Count)</strong></p>
      <p>🍲 Oversized VMs: <strong>$($OversizedVMResults.Count)</strong></p>
      <p>🧊 Orphaned disks: <strong>$($OrphanedDiskResults.Count)</strong></p>
      <p>⏳ Expiration issues: <strong>$($ExpiredResourceResults.Count)</strong></p>
      <p>🌐 Unused IPs: <strong>$($PublicIPResults.Count)</strong></p>
      <p>🔓 Permissive NSGs: <strong>$($SecurityGroupResults.Count)</strong></p>
    </div>

    <h2>PaaS Services Using Premium SKUs</h2>
"@

if ($PaaSPremiumResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Resource Name</th><th>Resource Type</th><th>Resource Group</th><th>Location</th><th>Current SKU</th><th>Tags</th></tr>"
    foreach ($result in $PaaSPremiumResults) {
        $htmlContent += "<tr><td>$($result.ResourceName)</td><td>$($result.ResourceType)</td><td>$($result.ResourceGroup)</td><td>$($result.Location)</td><td class='warning'>$($result.CurrentSKU)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>Good news: your dev/test kitchen has zero premium PaaS tiers simmering!</p>"
}

$htmlContent += @"
    <h2>VMs Missing Stop/Start Automation Tags</h2>
"@

if ($VMResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>VM Name</th><th>Resource Group</th><th>Location</th><th>Power State</th><th>VM Size</th><th>Current Tags</th></tr>"
    foreach ($result in $VMResults) {
        $htmlContent += "<tr><td>$($result.VMName)</td><td>$($result.ResourceGroup)</td><td>$($result.Location)</td><td>$($result.PowerState)</td><td>$($result.VMSize)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>All dev/test VMs are prepped with stop/start tags—no idle burners wasting resources!</p>"
}

$htmlContent += @"
    <h2>Oversized VMs for Dev/Test Environment</h2>
"@

if ($OversizedVMResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>VM Name</th><th>Resource Group</th><th>Location</th><th>Current Size</th><th>Power State</th><th>Tags</th></tr>"
    foreach ($result in $OversizedVMResults) {
        $htmlContent += "<tr><td>$($result.VMName)</td><td>$($result.ResourceGroup)</td><td>$($result.Location)</td><td class='warning'>$($result.CurrentSize)</td><td>$($result.PowerState)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>No oversized VMs lurking in your dev/test kitchen—everything’s just the right fit!</p>"
}

$htmlContent += @"
    <h2>Orphaned Disks</h2>
"@

if ($OrphanedDiskResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Disk Name</th><th>Resource Group</th><th>Location</th><th>Size (GB)</th><th>SKU</th><th>Created Date</th></tr>"
    foreach ($result in $OrphanedDiskResults) {
        $htmlContent += "<tr><td>$($result.DiskName)</td><td>$($result.ResourceGroup)</td><td>$($result.Location)</td><td>$($result.SizeGB)</td><td>$($result.SkuName)</td><td>$($result.CreatedDate)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>No orphaned disks found.</p>"
}

$htmlContent += @"
    <h2>Resource Groups Missing Expiration Tags</h2>
"@

if ($ExpiredResourceResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Resource Group</th><th>Location</th><th>Has Expiration Tag</th><th>Expiration Tag Name</th><th>Expiration Date</th><th>Is Expired</th><th>Resource Count</th><th>Created Date</th></tr>"
    foreach ($result in $ExpiredResourceResults) {
        $expirationClass = if ($result.IsExpired) { "class='warning'" } else { "" }
        $htmlContent += "<tr><td>$($result.ResourceGroupName)</td><td>$($result.Location)</td><td>$($result.HasExpirationTag)</td><td>$($result.ExpirationTagName)</td><td $expirationClass>$($result.ExpirationDate)</td><td $expirationClass>$($result.IsExpired)</td><td>$($result.ResourceCount)</td><td>$($result.CreatedDate)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>All dev/test resource groups have appropriate expiration tags.</p>"
}

$htmlContent += @"
    <h2>Unused Public IP Addresses</h2>
"@

if ($PublicIPResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Public IP Name</th><th>Resource Group</th><th>Location</th><th>IP Address</th><th>Allocation Method</th><th>SKU</th></tr>"
    foreach ($result in $PublicIPResults) {
        $htmlContent += "<tr><td>$($result.PublicIPName)</td><td>$($result.ResourceGroup)</td><td>$($result.Location)</td><td>$($result.IPAddress)</td><td>$($result.AllocationMethod)</td><td>$($result.SkuName)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>No unused public IP addresses found.</p>"
}

$htmlContent += @"
    <h2>Permissive Network Security Groups</h2>
"@

if ($SecurityGroupResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>NSG Name</th><th>Resource Group</th><th>Location</th><th>Permissive Rules Count</th><th>Rule Names</th></tr>"
    foreach ($result in $SecurityGroupResults) {
        $htmlContent += "<tr><td>$($result.NSGName)</td><td>$($result.ResourceGroup)</td><td>$($result.Location)</td><td class='warning'>$($result.PermissiveRulesCount)</td><td>$($result.RuleNames)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>No overly permissive network security groups found.</p>"
}

$htmlContent += @"
    <h2>🍽️ Chef’s Cost-Saving Recommendations</h2>
    <ul>
      <li><strong>🔽 PaaS Premium SKUs:</strong> Swap out “gourmet” tiers for Standard or Basic in dev/test kitchens and cut ingredient costs.</li>
      <li><strong>⏱️ VM Auto-Shutdown:</strong> Add stop/start automation after hours—think of it as turning off the stove when you’re not cooking.</li>
      <li><strong>📏 Right-Size VMs:</strong> Use leaner SKUs like B2s or D2s_v3 in dev/test. No need for a banquet when a snack will do.</li>
      <li><strong>🗑️ Orphaned Disks:</strong> Toss unattached disks—these dusty leftovers rack up serious charges.</li>
      <li><strong>🏷️ Expiration Tags:</strong> Tag RGs with “use-by” dates (ExpirationDate, TTL) so cleanup happens like clockwork.</li>
      <li><strong>🌐 Unused IPs:</strong> Reclaim static IPs you’re not using—every orphaned address adds to your monthly tab.</li>
      <li><strong>🔒 Tighten NSGs:</strong> Close wide-open firewall rules—keep dev/test safe without an all-you-can-access buffet.</li>
      <li><strong>📊 Budget Alerts:</strong> Cook up Azure Cost Management budgets & alerts to stay ahead of overspend before it boils over.</li>
    </ul>
    <div class='footer'>
      Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br>
      🍳 www.cloudcostchefs.com
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "HTML report saved to: $htmlPath" -ForegroundColor Green

# Summary output
Write-Host "`nScan Complete!" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "- Total dev/test resources scanned: $($devTestResources.Count)"
Write-Host "- PaaS services with premium SKUs: $($PaaSPremiumResults.Count)"
Write-Host "- VMs missing stop/start tags: $($VMResults.Count)"
Write-Host "- Oversized VMs: $($OversizedVMResults.Count)"
Write-Host "- Orphaned disks: $($OrphanedDiskResults.Count)"
Write-Host "- Resource groups missing expiration tags: $($ExpiredResourceResults.Count)"
Write-Host "- Unused public IPs: $($PublicIPResults.Count)"
Write-Host "- Permissive security groups: $($SecurityGroupResults.Count)"

$totalIssues = $PaaSPremiumResults.Count + $VMResults.Count + $OversizedVMResults.Count + 
               $OrphanedDiskResults.Count + $ExpiredResourceResults.Count + 
               $PublicIPResults.Count + $SecurityGroupResults.Count

if ($totalIssues -gt 0) {
    Write-Host "`nTotal cost optimization opportunities found: $totalIssues" -ForegroundColor Yellow
    Write-Host "Chef’s Tip: Dig into the reports, trim the fat, and fine-tune your dev/test environments for a leaner, cost-savvy cloud kitchen." -ForegroundColor Yellow
} else {
    Write-Host "`n🎉 Your dev/test kitchen is spotless—no cost cleanup needed!" -ForegroundColor Green
}
