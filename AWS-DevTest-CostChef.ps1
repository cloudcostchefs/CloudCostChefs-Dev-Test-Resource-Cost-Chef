#Requires -Modules AWS.Tools.EC2, AWS.Tools.RDS, AWS.Tools.ElastiCache, AWS.Tools.ELB, AWS.Tools.S3

<#
.SYNOPSIS
    🍳 CloudCostChefs Dev/Test Resource Cost Chef – AWS Edition

.DESCRIPTION
    This PowerShell recipe scans your AWS account for resources tagged as dev/test
    and serves up a multi-course report highlighting cost optimizations:
      • RDS instances running production-grade sizes (time to downsize!)
      • EC2 instances missing stop/start automation tags (idle compute bills lurking)
      • Oversized EC2 instances in your dev/test environments
      • Unattached EBS volumes gathering dust
      • Unused Elastic IPs quietly simmering cost
      • ElastiCache clusters running premium node types
      • Load balancers with no targets (empty serving trays)
      • Overly permissive Security Groups (open-door policies)

    Outputs:
      • CSV files for each issue category
      • A CloudCostChefs–styled HTML report you can plate and share

.PARAMETER Region
    (String) AWS region to scan; defaults to current configured region.

.PARAMETER OutputPath
    (String) Folder path for CSV & HTML reports (default: current directory).

.PARAMETER DevTestTags
    (String[]) Tag values to recognize dev/test resources
    (default: 'dev','test','development','testing','staging','qa').

.PARAMETER SuppressWarnings
    (Bool) Silently suppress AWS PowerShell breaking change warnings
    for a clean console output (default: $true).

.EXAMPLE
    # Quick audit with defaults:
    .\AWS-DevTest-CostChef.ps1

.EXAMPLE
    # Target specific region:
    .\AWS-DevTest-CostChef.ps1 -Region "us-west-2" -OutputPath "C:\Reports"
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Region,
    
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
}

# — Ensure AWS modules are available —
$requiredModules = @('AWS.Tools.EC2', 'AWS.Tools.RDS', 'AWS.Tools.ElastiCache', 'AWS.Tools.ELB', 'AWS.Tools.S3')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "🔧 Installing $module..." -ForegroundColor Yellow
        Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
    }
    Import-Module $module -Force
}

# Connect to AWS if not already connected
try {
    $awsCredentials = Get-AWSCredential
    if (-not $awsCredentials) {
        Write-Error "❌ AWS credentials not found. Configure with Set-AWSCredential or AWS CLI."
        exit 1
    }
    
    if ($Region) {
        Set-DefaultAWSRegion -Region $Region
    }
    
    $currentRegion = Get-DefaultAWSRegion
    if (-not $currentRegion) {
        Set-DefaultAWSRegion -Region "us-east-1"
        $currentRegion = "us-east-1"
    }
    
    Write-Host "🍽️ Using AWS Region: $currentRegion" -ForegroundColor Green
}
catch {
    Write-Error "❌ Failed AWS authentication: $($_.Exception.Message)"
    exit 1
}

# — Ingredient lists —
$ProductionRDSClasses = @(
    'db.r5.large', 'db.r5.xlarge', 'db.r5.2xlarge', 'db.r5.4xlarge', 'db.r5.8xlarge',
    'db.r4.large', 'db.r4.xlarge', 'db.r4.2xlarge', 'db.r4.4xlarge', 'db.r4.8xlarge',
    'db.m5.large', 'db.m5.xlarge', 'db.m5.2xlarge', 'db.m5.4xlarge', 'db.m5.8xlarge',
    'db.m4.large', 'db.m4.xlarge', 'db.m4.2xlarge', 'db.m4.4xlarge', 'db.m4.10xlarge'
)

$OversizedEC2Types = @(
    'm5.large', 'm5.xlarge', 'm5.2xlarge', 'm5.4xlarge', 'm5.8xlarge',
    'c5.large', 'c5.xlarge', 'c5.2xlarge', 'c5.4xlarge', 'c5.9xlarge',
    'r5.large', 'r5.xlarge', 'r5.2xlarge', 'r5.4xlarge', 'r5.8xlarge',
    'm4.large', 'm4.xlarge', 'm4.2xlarge', 'm4.4xlarge', 'm4.10xlarge'
)

$PremiumElastiCacheNodes = @(
    'cache.r6g.large', 'cache.r6g.xlarge', 'cache.r6g.2xlarge', 'cache.r6g.4xlarge',
    'cache.r5.large', 'cache.r5.xlarge', 'cache.r5.2xlarge', 'cache.r5.4xlarge',
    'cache.m6g.large', 'cache.m6g.xlarge', 'cache.m6g.2xlarge', 'cache.m6g.4xlarge'
)

# — Prepare result bowls —
$RDSResults = @()
$EC2Results = @()
$OversizedEC2Results = @()
$UnattachedEBSResults = @()
$UnusedEIPResults = @()
$ElastiCacheResults = @()
$LoadBalancerResults = @()
$SecurityGroupResults = @()

Write-Host "Scanning AWS resources for dev/test cost optimizations..." -ForegroundColor Yellow

# Helper function to check if resource has dev/test tags
function Test-DevTestResource {
    param([object]$Tags)
    
    if (-not $Tags) { return $false }
    
    foreach ($tag in $Tags) {
        if ($DevTestTags -contains $tag.Value.ToLower()) {
            return $true
        }
    }
    return $false
}

# Helper function to check for automation tags
function Test-AutomationTags {
    param([object]$Tags)
    
    if (-not $Tags) { return $false }
    
    $automationTags = @('AutoShutdown', 'AutoStart', 'Schedule', 'StopStart', 'Automation')
    foreach ($tag in $Tags) {
        foreach ($autoTag in $automationTags) {
            if ($tag.Key -like "*$autoTag*") {
                return $true
            }
        }
    }
    return $false
}

# Helper function to format tags
function Format-Tags {
    param([object]$Tags)
    
    if (-not $Tags) { return "N/A" }
    return ($Tags | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
}

# 1. Check RDS instances for production-grade sizes
try {
    Write-Host "🗄️ Checking RDS instances..." -ForegroundColor Cyan
    $rdsInstances = Get-RDSDBInstance
    
    foreach ($rds in $rdsInstances) {
        $tags = Get-RDSTagForResource -ResourceName $rds.DBInstanceArn
        
        if (Test-DevTestResource -Tags $tags) {
            if ($ProductionRDSClasses -contains $rds.DBInstanceClass) {
                $RDSResults += [PSCustomObject]@{
                    DBInstanceIdentifier = $rds.DBInstanceIdentifier
                    DBInstanceClass = $rds.DBInstanceClass
                    Engine = $rds.Engine
                    EngineVersion = $rds.EngineVersion
                    Status = $rds.DBInstanceStatus
                    MultiAZ = $rds.MultiAZ
                    AllocatedStorage = $rds.AllocatedStorage
                    AvailabilityZone = $rds.AvailabilityZone
                    Tags = Format-Tags -Tags $tags
                    DBInstanceArn = $rds.DBInstanceArn
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve RDS information: $($_.Exception.Message)"
}

# 2. Check EC2 instances for missing automation tags and oversized instances
try {
    Write-Host "🖥️ Checking EC2 instances..." -ForegroundColor Cyan
    $ec2Instances = Get-EC2Instance
    
    foreach ($reservation in $ec2Instances) {
        foreach ($instance in $reservation.Instances) {
            if (Test-DevTestResource -Tags $instance.Tags) {
                $hasAutomationTag = Test-AutomationTags -Tags $instance.Tags
                
                # Check for missing automation tags
                if (-not $hasAutomationTag) {
                    $EC2Results += [PSCustomObject]@{
                        InstanceId = $instance.InstanceId
                        InstanceType = $instance.InstanceType
                        State = $instance.State.Name
                        LaunchTime = $instance.LaunchTime
                        AvailabilityZone = $instance.Placement.AvailabilityZone
                        Platform = if ($instance.Platform) { $instance.Platform } else { "Linux" }
                        HasAutomationTag = $hasAutomationTag
                        Tags = Format-Tags -Tags $instance.Tags
                    }
                }
                
                # Check for oversized instances
                if ($OversizedEC2Types -contains $instance.InstanceType) {
                    $OversizedEC2Results += [PSCustomObject]@{
                        InstanceId = $instance.InstanceId
                        InstanceType = $instance.InstanceType
                        State = $instance.State.Name
                        LaunchTime = $instance.LaunchTime
                        AvailabilityZone = $instance.Placement.AvailabilityZone
                        Platform = if ($instance.Platform) { $instance.Platform } else { "Linux" }
                        Tags = Format-Tags -Tags $instance.Tags
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve EC2 information: $($_.Exception.Message)"
}

# 3. Check for unattached EBS volumes
try {
    Write-Host "💽 Checking EBS volumes..." -ForegroundColor Cyan
    $ebsVolumes = Get-EC2Volume | Where-Object { $_.State -eq 'available' }
    
    foreach ($volume in $ebsVolumes) {
        $tags = $volume.Tags
        if (Test-DevTestResource -Tags $tags) {
            $UnattachedEBSResults += [PSCustomObject]@{
                VolumeId = $volume.VolumeId
                Size = $volume.Size
                VolumeType = $volume.VolumeType
                Iops = $volume.Iops
                CreateTime = $volume.CreateTime
                AvailabilityZone = $volume.AvailabilityZone
                Encrypted = $volume.Encrypted
                Tags = Format-Tags -Tags $tags
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve EBS volume information: $($_.Exception.Message)"
}

# 4. Check for unused Elastic IPs
try {
    Write-Host "🌐 Checking Elastic IPs..." -ForegroundColor Cyan
    $elasticIPs = Get-EC2Address | Where-Object { -not $_.InstanceId -and -not $_.NetworkInterfaceId }
    
    foreach ($eip in $elasticIPs) {
        $tags = $eip.Tags
        if (Test-DevTestResource -Tags $tags) {
            $UnusedEIPResults += [PSCustomObject]@{
                AllocationId = $eip.AllocationId
                PublicIp = $eip.PublicIp
                Domain = $eip.Domain
                Tags = Format-Tags -Tags $tags
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Elastic IP information: $($_.Exception.Message)"
}

# 5. Check ElastiCache for premium node types
try {
    Write-Host "🔄 Checking ElastiCache clusters..." -ForegroundColor Cyan
    $elastiCacheClusters = Get-ECCacheCluster
    
    foreach ($cluster in $elastiCacheClusters) {
        $tags = Get-ECTagForResource -ResourceName $cluster.ARN
        
        if (Test-DevTestResource -Tags $tags) {
            if ($PremiumElastiCacheNodes -contains $cluster.CacheNodeType) {
                $ElastiCacheResults += [PSCustomObject]@{
                    CacheClusterId = $cluster.CacheClusterId
                    CacheNodeType = $cluster.CacheNodeType
                    Engine = $cluster.Engine
                    EngineVersion = $cluster.EngineVersion
                    NumCacheNodes = $cluster.NumCacheNodes
                    ClusterStatus = $cluster.CacheClusterStatus
                    AvailabilityZone = $cluster.AvailabilityZone
                    Tags = Format-Tags -Tags $tags
                    ARN = $cluster.ARN
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve ElastiCache information: $($_.Exception.Message)"
}

# 6. Check Load Balancers with no targets
try {
    Write-Host "⚖️ Checking Load Balancers..." -ForegroundColor Cyan
    $loadBalancers = Get-ELB2LoadBalancer
    
    foreach ($lb in $loadBalancers) {
        $tags = Get-ELB2Tag -ResourceArn $lb.LoadBalancerArn
        
        if (Test-DevTestResource -Tags $tags.TagList) {
            $targetGroups = Get-ELB2TargetGroup | Where-Object { $_.LoadBalancerArns -contains $lb.LoadBalancerArn }
            $hasTargets = $false
            
            foreach ($tg in $targetGroups) {
                $targets = Get-ELB2TargetHealth -TargetGroupArn $tg.TargetGroupArn
                if ($targets.Count -gt 0) {
                    $hasTargets = $true
                    break
                }
            }
            
            if (-not $hasTargets) {
                $LoadBalancerResults += [PSCustomObject]@{
                    LoadBalancerName = $lb.LoadBalancerName
                    LoadBalancerArn = $lb.LoadBalancerArn
                    Type = $lb.Type
                    Scheme = $lb.Scheme
                    State = $lb.State.Code
                    CreatedTime = $lb.CreatedTime
                    AvailabilityZones = ($lb.AvailabilityZones | ForEach-Object { $_.ZoneName }) -join ', '
                    Tags = Format-Tags -Tags $tags.TagList
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Load Balancer information: $($_.Exception.Message)"
}

# 7. Check for overly permissive Security Groups
try {
    Write-Host "🔒 Checking Security Groups..." -ForegroundColor Cyan
    $securityGroups = Get-EC2SecurityGroup
    
    foreach ($sg in $securityGroups) {
        if (Test-DevTestResource -Tags $sg.Tags) {
            $permissiveRules = $sg.IpPermissions | Where-Object {
                $_.IpRanges.CidrIp -contains '0.0.0.0/0' -and
                ($_.FromPort -eq 22 -or $_.FromPort -eq 3389 -or $_.FromPort -eq 0)
            }
            
            if ($permissiveRules.Count -gt 0) {
                $SecurityGroupResults += [PSCustomObject]@{
                    GroupId = $sg.GroupId
                    GroupName = $sg.GroupName
                    Description = $sg.Description
                    VpcId = $sg.VpcId
                    PermissiveRulesCount = $permissiveRules.Count
                    PermissivePorts = ($permissiveRules | ForEach-Object { 
                        if ($_.FromPort -eq $_.ToPort) { $_.FromPort } 
                        else { "$($_.FromPort)-$($_.ToPort)" } 
                    }) -join ', '
                    Tags = Format-Tags -Tags $sg.Tags
                }
            }
        }
    }
}
catch {
    Write-Warning "Could not retrieve Security Group information: $($_.Exception.Message)"
}

# — Reports: CSV & HTML —
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
Write-Host "Generating reports..." -ForegroundColor Yellow

$reportTypes = @(
    @{ Data = $RDSResults; Name = "RDS_Production_Sizes" },
    @{ Data = $EC2Results; Name = "EC2_Missing_Automation_Tags" },
    @{ Data = $OversizedEC2Results; Name = "Oversized_EC2_Instances" },
    @{ Data = $UnattachedEBSResults; Name = "Unattached_EBS_Volumes" },
    @{ Data = $UnusedEIPResults; Name = "Unused_Elastic_IPs" },
    @{ Data = $ElastiCacheResults; Name = "Premium_ElastiCache_Nodes" },
    @{ Data = $LoadBalancerResults; Name = "Empty_Load_Balancers" },
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
$htmlPath = Join-Path $OutputPath "AWS_DevTest_Resource_Report_$timestamp.html"

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>AWS Dev/Test Resource Cost Chef Report</title>
    <style>
        body { font-family: 'Amazon Ember', Arial, sans-serif; margin: 20px; background-color: #f9f9f9; }
        .container { background-color: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1, h2 { color: #232f3e; }
        h1 { border-bottom: 3px solid #ff9900; padding-bottom: 10px; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 30px; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background: linear-gradient(135deg, #232f3e 0%, #37475a 100%); color: white; font-weight: bold; }
        tr:nth-child(even) { background-color: #f2f3f3; }
        tr:hover { background-color: #e3f2fd; }
        .summary { background: linear-gradient(135deg, #ff9900 0%, #ffad33 100%); color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .warning { color: #d13212; font-weight: bold; }
        .timestamp { color: #666; font-size: 0.9em; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; text-align: center; color: #666; }
        .metric { font-weight: bold; font-size: 1.1em; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🍳 AWS Dev/Test Resource Cost Chef Report</h1>
        <div class="timestamp">Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Region: $currentRegion</div>
        
        <div class='summary'>
            <h3 style="margin-top: 0; color: white;">🔍 Cost Optimization Opportunities</h3>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px;">
                <div>📊 RDS Production Sizes: <span class="metric">$($RDSResults.Count)</span></div>
                <div>🚦 EC2 Missing Auto-Tags: <span class="metric">$($EC2Results.Count)</span></div>
                <div>🍖 Oversized EC2s: <span class="metric">$($OversizedEC2Results.Count)</span></div>
                <div>💽 Unattached EBS: <span class="metric">$($UnattachedEBSResults.Count)</span></div>
                <div>🌐 Unused Elastic IPs: <span class="metric">$($UnusedEIPResults.Count)</span></div>
                <div>🔄 Premium ElastiCache: <span class="metric">$($ElastiCacheResults.Count)</span></div>
                <div>⚖️ Empty Load Balancers: <span class="metric">$($LoadBalancerResults.Count)</span></div>
                <div>🔓 Permissive Security Groups: <span class="metric">$($SecurityGroupResults.Count)</span></div>
            </div>
        </div>

        <h2>🗄️ RDS Instances Using Production-Grade Sizes</h2>
"@

if ($RDSResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>DB Instance</th><th>Instance Class</th><th>Engine</th><th>Status</th><th>Multi-AZ</th><th>Storage (GB)</th><th>AZ</th><th>Tags</th></tr>"
    foreach ($result in $RDSResults) {
        $htmlContent += "<tr><td>$($result.DBInstanceIdentifier)</td><td class='warning'>$($result.DBInstanceClass)</td><td>$($result.Engine)</td><td>$($result.Status)</td><td>$($result.MultiAZ)</td><td>$($result.AllocatedStorage)</td><td>$($result.AvailabilityZone)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ Excellent! All dev/test RDS instances are using appropriate sizes.</p>"
}

$htmlContent += "<h2>🖥️ EC2 Instances Missing Automation Tags</h2>"

if ($EC2Results.Count -gt 0) {
    $htmlContent += "<table><tr><th>Instance ID</th><th>Instance Type</th><th>State</th><th>Launch Time</th><th>Platform</th><th>AZ</th><th>Tags</th></tr>"
    foreach ($result in $EC2Results) {
        $htmlContent += "<tr><td>$($result.InstanceId)</td><td>$($result.InstanceType)</td><td>$($result.State)</td><td>$($result.LaunchTime)</td><td>$($result.Platform)</td><td>$($result.AvailabilityZone)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ All dev/test EC2 instances have automation tags configured!</p>"
}

$htmlContent += "<h2>🍖 Oversized EC2 Instances for Dev/Test</h2>"

if ($OversizedEC2Results.Count -gt 0) {
    $htmlContent += "<table><tr><th>Instance ID</th><th>Instance Type</th><th>State</th><th>Launch Time</th><th>Platform</th><th>AZ</th><th>Tags</th></tr>"
    foreach ($result in $OversizedEC2Results) {
        $htmlContent += "<tr><td>$($result.InstanceId)</td><td class='warning'>$($result.InstanceType)</td><td>$($result.State)</td><td>$($result.LaunchTime)</td><td>$($result.Platform)</td><td>$($result.AvailabilityZone)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ No oversized EC2 instances found in dev/test environments!</p>"
}

$htmlContent += "<h2>💽 Unattached EBS Volumes</h2>"

if ($UnattachedEBSResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Volume ID</th><th>Size (GB)</th><th>Type</th><th>IOPS</th><th>Created</th><th>AZ</th><th>Encrypted</th><th>Tags</th></tr>"
    foreach ($result in $UnattachedEBSResults) {
        $htmlContent += "<tr><td>$($result.VolumeId)</td><td>$($result.Size)</td><td>$($result.VolumeType)</td><td>$($result.Iops)</td><td>$($result.CreateTime)</td><td>$($result.AvailabilityZone)</td><td>$($result.Encrypted)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ No unattached EBS volumes found!</p>"
}

$htmlContent += "<h2>🌐 Unused Elastic IP Addresses</h2>"

if ($UnusedEIPResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Allocation ID</th><th>Public IP</th><th>Domain</th><th>Tags</th></tr>"
    foreach ($result in $UnusedEIPResults) {
        $htmlContent += "<tr><td>$($result.AllocationId)</td><td>$($result.PublicIp)</td><td>$($result.Domain)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ No unused Elastic IP addresses found!</p>"
}

$htmlContent += "<h2>🔄 ElastiCache Premium Node Types</h2>"

if ($ElastiCacheResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Cluster ID</th><th>Node Type</th><th>Engine</th><th>Nodes</th><th>Status</th><th>AZ</th><th>Tags</th></tr>"
    foreach ($result in $ElastiCacheResults) {
        $htmlContent += "<tr><td>$($result.CacheClusterId)</td><td class='warning'>$($result.CacheNodeType)</td><td>$($result.Engine)</td><td>$($result.NumCacheNodes)</td><td>$($result.ClusterStatus)</td><td>$($result.AvailabilityZone)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ All ElastiCache clusters are using appropriate node types!</p>"
}

$htmlContent += "<h2>⚖️ Load Balancers with No Targets</h2>"

if ($LoadBalancerResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Load Balancer</th><th>Type</th><th>Scheme</th><th>State</th><th>Created</th><th>AZs</th><th>Tags</th></tr>"
    foreach ($result in $LoadBalancerResults) {
        $htmlContent += "<tr><td>$($result.LoadBalancerName)</td><td>$($result.Type)</td><td>$($result.Scheme)</td><td>$($result.State)</td><td>$($result.CreatedTime)</td><td>$($result.AvailabilityZones)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ All load balancers have active targets!</p>"
}

$htmlContent += "<h2>🔓 Permissive Security Groups</h2>"

if ($SecurityGroupResults.Count -gt 0) {
    $htmlContent += "<table><tr><th>Group ID</th><th>Group Name</th><th>VPC</th><th>Permissive Rules</th><th>Open Ports</th><th>Tags</th></tr>"
    foreach ($result in $SecurityGroupResults) {
        $htmlContent += "<tr><td>$($result.GroupId)</td><td>$($result.GroupName)</td><td>$($result.VpcId)</td><td class='warning'>$($result.PermissiveRulesCount)</td><td class='warning'>$($result.PermissivePorts)</td><td>$($result.Tags)</td></tr>"
    }
    $htmlContent += "</table>"
} else {
    $htmlContent += "<p>✅ No overly permissive security groups found!</p>"
}

$htmlContent += @"
        <h2>🍽️ Chef's AWS Cost-Saving Recommendations</h2>
        <ul>
            <li><strong>🔽 RDS Right-Sizing:</strong> Switch to db.t3.micro, db.t3.small, or db.t3.medium for dev/test databases—production power isn't needed for testing recipes.</li>
            <li><strong>⏱️ EC2 Auto-Shutdown:</strong> Tag instances with automation schedules to stop after hours—your AWS bill will thank you for turning off the oven.</li>
            <li><strong>📏 EC2 Right-Sizing:</strong> Use t3.micro, t3.small, or burstable instances for dev/test—no need for large servings when a small plate will do.</li>
            <li><strong>💽 EBS Cleanup:</strong> Delete unattached volumes—these orphaned ingredients are still charging you storage fees.</li>
            <li><strong>🌐 Release Elastic IPs:</strong> Return unused static IPs to AWS—each idle IP costs $3.65/month when not attached.</li>
            <li><strong>🔄 ElastiCache Downsizing:</strong> Use cache.t3.micro or cache.t3.small nodes for testing—premium caching is overkill for dev environments.</li>
            <li><strong>⚖️ Load Balancer Cleanup:</strong> Remove ALBs/NLBs with no targets—empty serving trays cost $16-18/month each.</li>
            <li><strong>🔒 Security Group Tightening:</strong> Close unnecessary 0.0.0.0/0 rules—keep your dev kitchen secure without leaving doors wide open.</li>
            <li><strong>💰 Reserved Instances:</strong> Consider RIs for long-running dev/test workloads to save 40-60% on compute costs.</li>
            <li><strong>📊 Cost Budgets:</strong> Set up AWS Budgets with alerts to catch cost spikes before they burn your wallet.</li>
        </ul>
        
        <div class='footer'>
            <p>Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Region: $currentRegion</p>
            <p>🍳 CloudCostChefs - Serving up AWS savings, one resource at a time</p>
        </div>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "HTML report saved to: $htmlPath" -ForegroundColor Green

# Summary output
Write-Host "`n🍳 AWS Dev/Test Scan Complete!" -ForegroundColor Green
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "- RDS instances with production sizes: $($RDSResults.Count)"
Write-Host "- EC2 instances missing automation tags: $($EC2Results.Count)"
Write-Host "- Oversized EC2 instances: $($OversizedEC2Results.Count)"
Write-Host "- Unattached EBS volumes: $($UnattachedEBSResults.Count)"
Write-Host "- Unused Elastic IPs: $($UnusedEIPResults.Count)"
Write-Host "- Premium ElastiCache nodes: $($ElastiCacheResults.Count)"
Write-Host "- Empty load balancers: $($LoadBalancerResults.Count)"
Write-Host "- Permissive security groups: $($SecurityGroupResults.Count)"

$totalIssues = $RDSResults.Count + $EC2Results.Count + $OversizedEC2Results.Count + 
               $UnattachedEBSResults.Count + $UnusedEIPResults.Count + 
               $ElastiCacheResults.Count + $LoadBalancerResults.Count + $SecurityGroupResults.Count

if ($totalIssues -gt 0) {
    Write-Host "`nTotal cost optimization opportunities found: $totalIssues" -ForegroundColor Yellow
    Write-Host "Chef's Tip: Review the detailed reports and start cooking up some serious AWS savings!" -ForegroundColor Yellow
} else {
    Write-Host "`n🎉 Your AWS dev/test kitchen is perfectly optimized—no waste detected!" -ForegroundColor Green
}

# Open HTML report
try {
    Start-Process $htmlPath
    Write-Host "Opening HTML report in default browser..." -ForegroundColor Cyan
} catch {
    Write-Host "Could not auto-open HTML report. Please open manually: $htmlPath" -ForegroundColor Yellow
}
