<#
.SYNOPSIS
    🍳 CloudCostChefs Dev/Test Resource Cost Chef – GCP Edition

.DESCRIPTION
    This PowerShell recipe scans your GCP project for resources labeled as dev/test
    and serves up a multi-course report highlighting cost optimizations:
      • Cloud SQL instances running production-grade sizes (time to downsize!)
      • Compute Engine instances missing stop/start automation labels (idle compute bills lurking)
      • Oversized Compute Engine instances in your dev/test environments
      • Unattached persistent disks gathering dust
      • Unused static IP addresses quietly simmering cost
      • Cloud Memorystore instances running premium tiers
      • Load balancers with no backends (empty serving trays)
      • Overly permissive firewall rules (open-door policies)

    Outputs:
      • CSV files for each issue category
      • A CloudCostChefs–styled HTML report you can plate and share

.PARAMETER Project
    (String) GCP project ID to scan; defaults to current gcloud configured project.

.PARAMETER Zone
    (String) GCP zone to scan; if not specified, scans all zones in the project.

.PARAMETER OutputPath
    (String) Folder path for CSV & HTML reports (default: current directory).

.PARAMETER DevTestLabels
    (String[]) Label values to recognize dev/test resources
    (default: 'dev','test','development','testing','staging','qa').

.EXAMPLE
    # Quick audit with defaults:
    .\GCP-DevTest-CostChef.ps1

.EXAMPLE
    # Target specific project and zone:
    .\GCP-DevTest-CostChef.ps1 -Project "my-dev-project" -Zone "us-central1-a" -OutputPath "C:\Reports"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Project,
    
    [Parameter(Mandatory=$false)]
    [string]$Zone,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory=$false)]
    [string[]]$DevTestLabels = @('dev', 'test', 'development', 'testing', 'staging', 'qa')
)

# Check if gcloud CLI is available
try {
    $gcloudVersion = & gcloud version 2>$null
    if (-not $gcloudVersion) {
        throw "gcloud CLI not found"
    }
}
catch {
    Write-Error "❌ Google Cloud SDK (gcloud) is required. Install from: https://cloud.google.com/sdk"
    exit 1
}

# Check authentication
try {
    $authResult = & gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null
    if (-not $authResult) {
        Write-Error "❌ Not authenticated with gcloud. Run: gcloud auth login"
        exit 1
    }
    Write-Host "🔑 Authenticated as: $authResult" -ForegroundColor Green
}
catch {
    Write-Error "❌ Failed to check gcloud authentication: $($_.Exception.Message)"
    exit 1
}

# Set project if specified, otherwise use current
if ($Project) {
    & gcloud config set project $Project 2>$null
} else {
    $Project = & gcloud config get-value project 2>$null
    if (-not $Project) {
        Write-Error "❌ No project specified and no default project set. Use: gcloud config set project PROJECT_ID"
        exit 1
    }
}

Write-Host "🍽️ Using GCP Project: $Project" -ForegroundColor Green

# — Ingredient lists —
$ProductionSQLTiers = @(
    'db-n1-standard-2', 'db-n1-standard-4', 'db-n1-standard-8', 'db-n1-standard-16',
    'db-n1-highmem-2', 'db-n1-highmem-4', 'db-n1-highmem-8', 'db-n1-highmem-16',
    'db-custom-2-8192', 'db-custom-4-16384', 'db-custom-8-32768'
)

$OversizedMachineTypes = @(
    'n1-standard-2', 'n1-standard-4', 'n1-standard-8', 'n1-standard-16',
    'n1-highmem-2', 'n1-highmem-4', 'n1-highmem-8', 'n1-highmem-16',
    'c2-standard-4', 'c2-standard-8', 'c2-standard-16',
    'n2-standard-4', 'n2-standard-8', 'n2-standard-16'
)

$PremiumMemorystoreTiers = @(
    'STANDARD_HA', 'PREMIUM'
)

# — Prepare result bowls —
$CloudSQLResults = @()
$ComputeEngineResults = @()
$OversizedComputeResults = @()
$UnattachedDiskResults = @()
$UnusedIPResults = @()
$MemorystoreResults = @()
$LoadBalancerResults = @()
$FirewallResults = @()

Write-Host "Scanning GCP resources for dev/test cost optimizations..." -ForegroundColor Yellow

# Helper function to check if resource has dev/test labels
function Test-DevTestResource {
    param([string]$LabelsJson)
    
    if (-not $LabelsJson -or $LabelsJson -eq 'null' -or $LabelsJson -eq '{}') { 
        return $false 
    }
    
    try {
        $labels = $LabelsJson | ConvertFrom-Json
        foreach ($property in $labels.PSObject.Properties) {
            if ($DevTestLabels -contains $property.Value.ToLower()) {
                return $true
            }
        }
    }
    catch {
        # If JSON parsing fails, try simple string matching
        foreach ($label in $DevTestLabels) {
            if ($LabelsJson -like "*$label*") {
                return $true
            }
        }
    }
    return $false
}

# Helper function to check for automation labels
function Test-AutomationLabels {
    param([string]$LabelsJson)
    
    if (-not $LabelsJson -or $LabelsJson -eq 'null' -or $LabelsJson -eq '{}') { 
        return $false 
    }
    
    $automationLabels = @('auto-shutdown', 'auto-start', 'schedule', 'stop-start', 'automation')
    
    try {
        $labels = $LabelsJson | ConvertFrom-Json
        foreach ($property in $labels.PSObject.Properties) {
            foreach ($autoLabel in $automationLabels) {
                if ($property.Name.ToLower() -like "*$autoLabel*") {
                    return $true
                }
            }
        }
    }
    catch {
        # If JSON parsing fails, try simple string matching
        foreach ($autoLabel in $automationLabels) {
            if ($LabelsJson -like "*$autoLabel*") {
                return $true
            }
        }
    }
    return $false
}

# Helper function to format labels
function Format-Labels {
    param([string]$LabelsJson)
    
    if (-not $LabelsJson -or $LabelsJson -eq 'null' -or $LabelsJson -eq '{}') { 
        return "N/A" 
    }
    
    try {
        $labels = $LabelsJson | ConvertFrom-Json
        $labelPairs = @()
        foreach ($property in $labels.PSObject.Properties) {
            $labelPairs += "$($property.Name)=$($property.Value)"
        }
        return $labelPairs -join '; '
    }
    catch {
        return $LabelsJson
    }
}

# 1. Check Cloud SQL instances for production-grade sizes
try {
    Write-Host "🗄️ Checking Cloud SQL instances..." -ForegroundColor Cyan
    $sqlInstancesJson = & gcloud sql instances list --format="json" --project=$Project 2>$null
    
    if ($sqlInstancesJson) {
        $sqlInstances = $sqlInstancesJson | ConvertFrom-Json
        
        foreach ($instance in $sqlInstances) {
            $labelsJson = if ($instance.settings.userLabels) { $instance.settings.userLabels | ConvertTo-Json -Compress } else { '{}' }
            
            if (Test-DevTestResource -LabelsJson $labelsJson) {
                if ($ProductionSQLTiers -contains $instance.settings.tier) {
                    $CloudSQLResults += [PSCustomObject]@{
                        InstanceName = $instance.name
                        Tier = $instance.settings.tier
                        DatabaseVersion = $instance.databaseVersion
                        State = $instance.state
                        Region = $instance.region
                        BackendType = $instance.backendType
                        DiskSize = if ($instance.settings.dataDiskSizeGb) { $instance.settings.dataDiskSizeGb } else { "N/A" }
                        DiskType = if ($instance.settings.dataDiskType) { $instance.settings.dataDiskType } else { "N/A" }
                        Labels = Format-Labels -LabelsJson $labelsJson
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Cloud SQL information: $($_.Exception.Message)"
}

# 2. Check Compute Engine instances for missing automation labels and oversized instances
try {
    Write-Host "🖥️ Checking Compute Engine instances..." -ForegroundColor Cyan
    
    $zoneParam = if ($Zone) { "--zones=$Zone" } else { "" }
    $computeInstancesJson = & gcloud compute instances list --format="json" --project=$Project $zoneParam 2>$null
    
    if ($computeInstancesJson) {
        $computeInstances = $computeInstancesJson | ConvertFrom-Json
        
        foreach ($instance in $computeInstances) {
            $labelsJson = if ($instance.labels) { $instance.labels | ConvertTo-Json -Compress } else { '{}' }
            
            if (Test-DevTestResource -LabelsJson $labelsJson) {
                $hasAutomationLabel = Test-AutomationLabels -LabelsJson $labelsJson
                $machineType = ($instance.machineType -split '/')[-1]
                
                # Check for missing automation labels
                if (-not $hasAutomationLabel) {
                    $ComputeEngineResults += [PSCustomObject]@{
                        InstanceName = $instance.name
                        MachineType = $machineType
                        Status = $instance.status
                        Zone = ($instance.zone -split '/')[-1]
                        CreationTimestamp = $instance.creationTimestamp
                        HasAutomationLabel = $hasAutomationLabel
                        Labels = Format-Labels -LabelsJson $labelsJson
                    }
                }
                
                # Check for oversized instances
                if ($OversizedMachineTypes -contains $machineType) {
                    $OversizedComputeResults += [PSCustomObject]@{
                        InstanceName = $instance.name
                        MachineType = $machineType
                        Status = $instance.status
                        Zone = ($instance.zone -split '/')[-1]
                        CreationTimestamp = $instance.creationTimestamp
                        Labels = Format-Labels -LabelsJson $labelsJson
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Compute Engine information: $($_.Exception.Message)"
}

# 3. Check for unattached persistent disks
try {
    Write-Host "💽 Checking persistent disks..." -ForegroundColor Cyan
    
    $zoneParam = if ($Zone) { "--zones=$Zone" } else { "" }
    $disksJson = & gcloud compute disks list --format="json" --project=$Project $zoneParam 2>$null
    
    if ($disksJson) {
        $disks = $disksJson | ConvertFrom-Json
        
        foreach ($disk in $disks) {
            if (-not $disk.users -or $disk.users.Count -eq 0) {
                $labelsJson = if ($disk.labels) { $disk.labels | ConvertTo-Json -Compress } else { '{}' }
                
                if (Test-DevTestResource -LabelsJson $labelsJson) {
                    $UnattachedDiskResults += [PSCustomObject]@{
                        DiskName = $disk.name
                        SizeGB = $disk.sizeGb
                        DiskType = ($disk.type -split '/')[-1]
                        Zone = ($disk.zone -split '/')[-1]
                        Status = $disk.status
                        CreationTimestamp = $disk.creationTimestamp
                        Labels = Format-Labels -LabelsJson $labelsJson
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve disk information: $($_.Exception.Message)"
}

# 4. Check for unused static IP addresses
try {
    Write-Host "🌐 Checking static IP addresses..." -ForegroundColor Cyan
    
    $addressesJson = & gcloud compute addresses list --format="json" --project=$Project 2>$null
    
    if ($addressesJson) {
        $addresses = $addressesJson | ConvertFrom-Json
        
        foreach ($address in $addresses) {
            if ($address.status -eq "RESERVED") {
                $labelsJson = if ($address.labels) { $address.labels | ConvertTo-Json -Compress } else { '{}' }
                
                if (Test-DevTestResource -LabelsJson $labelsJson) {
                    $UnusedIPResults += [PSCustomObject]@{
                        AddressName = $address.name
                        Address = $address.address
                        AddressType = $address.addressType
                        Status = $address.status
                        Region = if ($address.region) { ($address.region -split '/')[-1] } else { "Global" }
                        CreationTimestamp = $address.creationTimestamp
                        Labels = Format-Labels -LabelsJson $labelsJson
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve address information: $($_.Exception.Message)"
}

# 5. Check Cloud Memorystore for premium tiers
try {
    Write-Host "🔄 Checking Cloud Memorystore instances..." -ForegroundColor Cyan
    
    # Get list of regions first
    $regionsJson = & gcloud compute regions list --format="json" --project=$Project 2>$null
    if ($regionsJson) {
        $regions = $regionsJson | ConvertFrom-Json
        
        foreach ($region in $regions) {
            try {
                $memorystoreJson = & gcloud redis instances list --region=$($region.name) --format="json" --project=$Project 2>$null
                
                if ($memorystoreJson) {
                    $memorystoreInstances = $memorystoreJson | ConvertFrom-Json
                    
                    foreach ($instance in $memorystoreInstances) {
                        $labelsJson = if ($instance.labels) { $instance.labels | ConvertTo-Json -Compress } else { '{}' }
                        
                        if (Test-DevTestResource -LabelsJson $labelsJson) {
                            if ($PremiumMemorystoreTiers -contains $instance.tier) {
                                $MemorystoreResults += [PSCustomObject]@{
                                    InstanceName = $instance.name
                                    Tier = $instance.tier
                                    MemorySizeGb = $instance.memorySizeGb
                                    RedisVersion = $instance.redisVersion
                                    State = $instance.state
                                    Region = ($instance.locationId)
                                    Labels = Format-Labels -LabelsJson $labelsJson
                                }
                            }
                        }
                    }
                }
            }
            catch {
                # Some regions might not support Memorystore, continue silently
                continue
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Cloud Memorystore information: $($_.Exception.Message)"
}

# 6. Check Load Balancers with no backends
try {
    Write-Host "⚖️ Checking Load Balancers..." -ForegroundColor Cyan
    
    $loadBalancersJson = & gcloud compute forwarding-rules list --format="json" --project=$Project 2>$null
    
    if ($loadBalancersJson) {
        $loadBalancers = $loadBalancersJson | ConvertFrom-Json
        
        foreach ($lb in $loadBalancers) {
            if ($lb.target) {
                # Check if target has any backends
                $targetName = ($lb.target -split '/')[-1]
                $targetType = if ($lb.target -like "*targetHttpProxies*") { "target-http-proxies" } 
                             elseif ($lb.target -like "*targetHttpsProxies*") { "target-https-proxies" }
                             elseif ($lb.target -like "*targetPools*") { "target-pools" }
                             elseif ($lb.target -like "*backendServices*") { "backend-services" }
                             else { $null }
                
                if ($targetType) {
                    try {
                        $targetDetailsJson = & gcloud compute $targetType describe $targetName --format="json" --project=$Project 2>$null
                        if ($targetDetailsJson) {
                            $targetDetails = $targetDetailsJson | ConvertFrom-Json
                            $hasBackends = $false
                            
                            if ($targetDetails.backends -and $targetDetails.backends.Count -gt 0) {
                                $hasBackends = $true
                            } elseif ($targetDetails.instances -and $targetDetails.instances.Count -gt 0) {
                                $hasBackends = $true
                            }
                            
                            if (-not $hasBackends) {
                                $labelsJson = if ($lb.labels) { $lb.labels | ConvertTo-Json -Compress } else { '{}' }
                                
                                if (Test-DevTestResource -LabelsJson $labelsJson) {
                                    $LoadBalancerResults += [PSCustomObject]@{
                                        ForwardingRuleName = $lb.name
                                        Target = $targetName
                                        TargetType = $targetType
                                        IPAddress = $lb.IPAddress
                                        PortRange = $lb.portRange
                                        Region = if ($lb.region) { ($lb.region -split '/')[-1] } else { "Global" }
                                        CreationTimestamp = $lb.creationTimestamp
                                        Labels = Format-Labels -LabelsJson $labelsJson
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        # Continue if we can't get target details
                        continue
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Load Balancer information: $($_.Exception.Message)"
}

# 7. Check for overly permissive firewall rules
try {
    Write-Host "🔒 Checking firewall rules..." -ForegroundColor Cyan
    
    $firewallRulesJson = & gcloud compute firewall-rules list --format="json" --project=$Project 2>$null
    
    if ($firewallRulesJson) {
        $firewallRules = $firewallRulesJson | ConvertFrom-Json
        
        foreach ($rule in $firewallRules) {
            if ($rule.direction -eq "INGRESS" -and $rule.sourceRanges -contains "0.0.0.0/0") {
                # Check if it allows SSH (22) or RDP (3389) or all ports
                $isPermissive = $false
                if ($rule.allowed) {
                    foreach ($allowed in $rule.allowed) {
                        if (-not $allowed.ports -or $allowed.ports -contains "22" -or $allowed.ports -contains "3389" -or $allowed.ports -contains "0-65535") {
                            $isPermissive = $true
                            break
                        }
                    }
                }
                
                if ($isPermissive) {
                    # Check if this rule applies to dev/test resources (by network or tags)
                    $FirewallResults += [PSCustomObject]@{
                        RuleName = $rule.name
                        Direction = $rule.direction
                        Priority = $rule.priority
                        SourceRanges = ($rule.sourceRanges -join ', ')
                        AllowedPorts = if ($rule.allowed) { ($rule.allowed | ForEach-Object { "$($_.IPProtocol):$($_.ports -join ',')" }) -join '; ' } else { "N/A" }
                        TargetTags = if ($rule.targetTags) { ($rule.targetTags -join ', ') } else { "N/A" }
                        Network = ($rule.network -split '/')[-1]
                        CreationTimestamp = $rule.creationTimestamp
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve firewall rules information: $($_.Exception.Message)"
}

# — Reports: CSV & HTML —
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
Write-Host "Generating reports..." -ForegroundColor Yellow

$reportTypes = @(
    @{ Data = $CloudSQLResults; Name = "CloudSQL_Production_Sizes" },
    @{ Data = $ComputeEngineResults; Name = "ComputeEngine_Missing_Automation_Labels" },
    @{ Data = $OversizedComputeResults; Name = "Oversized_Compute_Instances" },
    @{ Data = $UnattachedDiskResults; Name = "Unattached_Persistent_Disks" },
    @{ Data = $UnusedIPResults; Name = "Unused_Static_IPs" },
    @{ Data = $MemorystoreResults; Name = "Premium_Memorystore_Instances" },
    @{ Data = $LoadBalancerResults; Name = "Empty_Load_Balancers" },
    @{ Data = $FirewallResults; Name = "Permissive_Firewall_Rules" }
)

foreach ($report in $reportTypes) {
    if ($report.Data.Count -gt 0) {
        $csvPath = Join-Path $OutputPath "$($report.Name)_$timestamp.csv"
        $report.Data | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "$($report.Name) CSV report saved to: $csvPath" -ForegroundColor Green
    }
}

# — HTML plating —
$htmlPath = Join-Path $OutputPath "GCP_DevTest_Resource_Report_$timestamp.html"

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>GCP Dev/Test Resource Cost Chef Report</title>
    <style>
        body { font-family: 'Google Sans', 'Roboto', Arial, sans-serif; margin: 20px; background-color: #f8f9fa; }
        .container { background-color: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        h1, h2 { color: #1a73e8; }
        h1 { border-bottom: 3px solid #4285f4; padding-bottom: 10px; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 30px; }
        th, td { border: 1px solid #dadce0; padding: 12px; text-align: left; }
        th { background: linear-gradient(135deg, #1a73e8 0%, #4285f4 100%); color: white; font-weight: bold; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        tr:hover { background-color: #e8f0fe; }
        .summary { background: linear-gradient(135deg, #4285f4 0%, #34a853 100%); color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .warning { color: #ea4335; font-weight: bold; }
        .timestamp { color: #5f6368; font-size: 0.9em; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #dadce0; text-align: center; color: #5f6368; }
        .metric { font-weight: bold; font-size: 1.1em; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🍳 GCP Dev/Test Resource Cost Chef Report</h1>
        <div class="timestamp">Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Project: $Project</div>
        
        <div class='summary'>
            <h3 style="margin-top: 0; color: white;">🔍 Cost Optimization Opportunities</h3>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px;">
                <div>📊 Cloud SQL Production Sizes: <span class="metric">$($CloudSQLResults.Count)</span></div>
                <div>🚦 Compute Missing Auto-Labels: <span class="metric">$($ComputeEngineResults.Count)</span></div>
                <div>🍖 Oversized Compute Instances: <span class="metric">$($OversizedComputeResults.Count)</span></div>
                <div>💽 Unattached Persistent Disks: <span class="metric">$($UnattachedDiskResults.Count)</span></div>
                <div>🌐 Unused Static IPs: <span class="metric">$($UnusedIPResults.Count)</span></div>
                <div>🔄 Premium Memorystore: <span class="metric">$($MemorystoreResults.Count)</span></div>
                <div>⚖️ Empty Load Balancers: <span class="metric">$($LoadBalancerResults.Count)</span></div>
                <div>🔓 Permissive Firewall Rules: <span class="metric">$($FirewallResults.Count)</span></div>
            </div>
        </div>

        <h2>🗄️ Cloud SQL Instances Using Production-Grade Sizes</h2>
"@

if ($CloudSQLResults.Count -gt 0) {
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ No unused static IP addresses found!</p>"
}

$htmlContent += "<h2>🔄 Cloud Memorystore Premium Tiers</h2>"

if ($MemorystoreResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Instance Name</th><th>Tier</th><th>Memory (GB)</th><th>Redis Version</th><th>State</th><th>Region</th><th>Labels</th></tr>"
    foreach ($result in $MemorystoreResults) {
        $htmlContent += "<tr><td>$($result.InstanceName)</td><td class='warning'>$($result.Tier)</td><td>$($result.MemorySizeGb)</td><td>$($result.RedisVersion)</td><td>$($result.State)</td><td>$($result.Region)</td><td>$($result.Labels)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ All Cloud Memorystore instances are using appropriate tiers!</p>"
}

$htmlContent += "<h2>⚖️ Load Balancers with No Backends</h2>"

if ($LoadBalancerResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Forwarding Rule</th><th>Target</th><th>Target Type</th><th>IP Address</th><th>Port Range</th><th>Region</th><th>Labels</th></tr>"
    foreach ($result in $LoadBalancerResults) {
        $htmlContent += "<tr><td>$($result.ForwardingRuleName)</td><td>$($result.Target)</td><td>$($result.TargetType)</td><td>$($result.IPAddress)</td><td>$($result.PortRange)</td><td>$($result.Region)</td><td>$($result.Labels)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ All load balancers have active backends!</p>"
}

$htmlContent += "<h2>🔓 Permissive Firewall Rules</h2>"

if ($FirewallResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Rule Name</th><th>Priority</th><th>Source Ranges</th><th>Allowed Ports</th><th>Target Tags</th><th>Network</th><th>Created</th></tr>"
    foreach ($result in $FirewallResults) {
        $htmlContent += "<tr><td>$($result.RuleName)</td><td>$($result.Priority)</td><td class='warning'>$($result.SourceRanges)</td><td class='warning'>$($result.AllowedPorts)</td><td>$($result.TargetTags)</td><td>$($result.Network)</td><td>$($result.CreationTimestamp)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ No overly permissive firewall rules found!</p>"
}

$htmlContent += @"
        <h2>🍽️ Chef's GCP Cost-Saving Recommendations</h2>
        <ul>
            <li><strong>🔽 Cloud SQL Right-Sizing:</strong> Switch to db-f1-micro, db-g1-small, or db-custom-1-3840 for dev/test databases—production power isn't needed for testing recipes.</li>
            <li><strong>⏱️ Compute Engine Auto-Shutdown:</strong> Label instances with automation schedules to stop after hours—your GCP bill will thank you for turning off the oven.</li>
            <li><strong>📏 Compute Right-Sizing:</strong> Use e2-micro, e2-small, f1-micro, or g1-small for dev/test—no need for large servings when a small plate will do.</li>
            <li><strong>💽 Persistent Disk Cleanup:</strong> Delete unattached disks—these orphaned ingredients are still charging you storage fees.</li>
            <li><strong>🌐 Release Static IPs:</strong> Return unused static IPs to GCP—each idle IP costs money when not attached to resources.</li>
            <li><strong>🔄 Memorystore Downsizing:</strong> Use BASIC tier instead of STANDARD_HA for testing—premium caching is overkill for dev environments.</li>
            <li><strong>⚖️ Load Balancer Cleanup:</strong> Remove load balancers with no backends—empty serving trays cost money without providing value.</li>
            <li><strong>🔒 Firewall Rule Tightening:</strong> Close unnecessary 0.0.0.0/0 rules—keep your dev kitchen secure without leaving doors wide open.</li>
            <li><strong>💰 Committed Use Discounts:</strong> Consider CUDs for long-running dev/test workloads to save 20-57% on compute costs.</li>
            <li><strong>📊 Cost Budgets:</strong> Set up GCP Budget alerts to catch cost spikes before they burn your wallet.</li>
            <li><strong>🏷️ Preemptible Instances:</strong> Use preemptible VMs for fault-tolerant dev/test workloads to save up to 80%.</li>
        </ul>
        
        <div class='footer'>
            <p>Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Project: $Project</p>
            <p>🍳 CloudCostChefs - Serving up GCP savings, one resource at a time</p>
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "HTML report saved to: $htmlPath" -ForegroundColor Green

# Summary output
Write-Host "`n🍳 GCP Dev/Test Scan Complete!" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "- Cloud SQL instances with production sizes: $($CloudSQLResults.Count)"
Write-Host "- Compute Engine instances missing automation labels: $($ComputeEngineResults.Count)"
Write-Host "- Oversized Compute Engine instances: $($OversizedComputeResults.Count)"
Write-Host "- Unattached persistent disks: $($UnattachedDiskResults.Count)"
Write-Host "- Unused static IP addresses: $($UnusedIPResults.Count)"
Write-Host "- Premium Memorystore instances: $($MemorystoreResults.Count)"
Write-Host "- Empty load balancers: $($LoadBalancerResults.Count)"
Write-Host "- Permissive firewall rules: $($FirewallResults.Count)"

$totalIssues = $CloudSQLResults.Count + $ComputeEngineResults.Count + $OversizedComputeResults.Count + 
               $UnattachedDiskResults.Count + $UnusedIPResults.Count + 
               $MemorystoreResults.Count + $LoadBalancerResults.Count + $FirewallResults.Count

if ($totalIssues -gt 0) {
    Write-Host "`nTotal cost optimization opportunities found: $totalIssues" -ForegroundColor Yellow
    Write-Host "Chef's Tip: Review the detailed reports and start cooking up some serious GCP savings!" -ForegroundColor Yellow
} else {
    Write-Host "`n🎉 Your GCP dev/test kitchen is perfectly optimized—no waste detected!" -ForegroundColor Green
}

# Open HTML report
try {
    Start-Process $htmlPath
    Write-Host "Opening HTML report in default browser..." -ForegroundColor Cyan
} catch {
    Write-Host "Could not auto-open HTML report. Please open manually: $htmlPath" -ForegroundColor Yellow
}

Write-Host "`n🍳 CloudCostChefs GCP Dev/Test Cost Chef completed successfully!" -ForegroundColor Green
