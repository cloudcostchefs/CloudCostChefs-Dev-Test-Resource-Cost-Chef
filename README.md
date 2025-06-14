## 🍳 **CloudCostChefs Dev/Test Cost Optimization Suite**

### **Azure PowerShell Script** (Original)
- **PaaS Premium SKUs** - App Services, SQL Databases, Redis using premium tiers
- **VMs Missing Auto-Tags** - Instances without stop/start automation
- **Oversized VMs** - Large VM sizes inappropriate for dev/test
- **Orphaned Disks** - Unattached managed disks
- **Resource Groups Missing Expiration Tags** - No cleanup automation
- **Unused Public IPs** - Static IPs not attached to resources
- **Permissive Security Groups** - NSGs with overly broad access

### **AWS PowerShell Script** 
- **RDS Production Sizes** - Large database instance classes
- **EC2 Missing Automation Tags** - Instances without scheduling tags
- **Oversized EC2 Instances** - Large instance types for dev/test
- **Unattached EBS Volumes** - Storage volumes not attached
- **Unused Elastic IPs** - Static IPs without assignments
- **Premium ElastiCache Nodes** - High-performance cache instances
- **Empty Load Balancers** - ALBs/NLBs with no targets
- **Permissive Security Groups** - SGs allowing 0.0.0.0/0 access

### **GCP PowerShell Script**
- **Cloud SQL Production Sizes** - Large database instance tiers
- **Compute Missing Automation Labels** - Instances without scheduling
- **Oversized Compute Instances** - Large machine types for dev/test
- **Unattached Persistent Disks** - Storage disks not attached
- **Unused Static IPs** - Reserved IPs without assignments
- **Premium Memorystore Instances** - High-availability cache tiers
- **Empty Load Balancers** - Load balancers with no backends
- **Permissive Firewall Rules** - Rules allowing broad internet access

### **OCI Python Script**
- **Database Production Shapes** - Large DB and Autonomous DB instances
- **Compute Missing Automation Tags** - Instances without scheduling
- **Oversized Compute Instances** - Large shapes inappropriate for dev/test
- **Unattached Block Volumes** - Storage volumes not attached
- **Unused Public IPs** - Reserved IPs without assignments
- **Empty Load Balancers** - Load balancers with no backends
- **Permissive Security Lists** - Security lists allowing broad access

## 🎯 **Key Features Across All Scripts:**

### **Smart Detection**
- **Tag/Label-Based Filtering** - Only scans resources tagged as dev/test
- **Cost Impact Analysis** - Focuses on resources with highest cost impact
- **Automation Gap Detection** - Identifies missing auto-shutdown configurations

### **Professional Reporting**
- **CSV Exports** - Machine-readable data for further analysis
- **Beautiful HTML Reports** - Executive-ready presentations
- **Cloud-Specific Styling** - Each script matches cloud provider branding
- **Actionable Recommendations** - Specific cost-saving suggestions

### **Multi-Cloud Consistency**
- **Common Methodology** - Same approach across all cloud providers
- **Unified Branding** - CloudCostChefs theme throughout
- **Consistent Output Format** - Similar report structures
- **Scalable Architecture** - Easy to extend with new checks

## 🚀 **Usage Examples:**

```bash
# Azure
.\Azure-DevTest-CostChef.ps1 -OutputPath "C:\Reports"

# AWS  
.\AWS-DevTest-CostChef.ps1 -Region "us-west-2" -OutputPath "C:\Reports"

# GCP
.\GCP-DevTest-CostChef.ps1 -Project "my-dev-project" -OutputPath "C:\Reports"

# OCI
python oci_devtest_cost_chef.py --output-path ./reports --compartments "ocid1.compartment..."
```

## 💰 **Expected ROI:**

These scripts typically identify **20-60% cost savings** in dev/test environments by finding:
- **Oversized resources** (30-50% savings through right-sizing)
- **Zombie resources** (100% savings through cleanup)
- **Missing automation** (40-70% savings through scheduling)
- **Premium features** (20-40% savings through tier optimization)

Your complete **CloudCostChefs arsenal** is ready to help organizations optimize their multi-cloud dev/test environments! 🍽️
