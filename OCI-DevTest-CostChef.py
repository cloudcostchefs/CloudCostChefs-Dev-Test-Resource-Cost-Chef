#!/usr/bin/env python3
# ===================================================================================
# 🍳 CloudCostChefs Dev/Test Resource Cost Chef – OCI Edition
# ===================================================================================

"""
CloudCostChefs: OCI Dev/Test Resource Cost Chef

This Python recipe scans your OCI tenancy for resources tagged as dev/test
and serves up a multi-course report highlighting cost optimizations:
  • Database instances running production-grade shapes (time to downsize!)
  • Compute instances missing stop/start automation tags (idle compute bills lurking)
  • Oversized Compute instances in your dev/test environments
  • Unattached block volumes gathering dust
  • Unused public IP addresses quietly simmering cost
  • Load balancers with no backends (empty serving trays)
  • Overly permissive security lists (open-door policies)

Outputs:
  • CSV files for each issue category
  • A CloudCostChefs–styled HTML report you can plate and share

Prerequisites:
    - OCI Python SDK: pip install oci
    - OCI CLI configured or config file present
    - Appropriate IAM permissions for compute, database, and networking services

Author: CloudCostChefs | @cloudcostchefs
Last Updated: 2025-06-10
Version: 1.0
"""

import argparse
import csv
import json
import logging
import os
import sys
import webbrowser
from datetime import datetime
from typing import Dict, List, Optional, Any

try:
    import oci
    from oci.config import from_file
    from oci.core import ComputeClient, BlockstorageClient, VirtualNetworkClient
    from oci.database import DatabaseClient
    from oci.load_balancer import LoadBalancerClient
    from oci.identity import IdentityClient
except ImportError:
    print("❌ OCI Python SDK not found. Install with: pip install oci")
    sys.exit(1)


class OCIDevTestCostChef:
    def __init__(self, config_path: str = None, profile: str = None):
        """Initialize OCI clients with configuration."""
        self.logger = self._setup_logging()
        self.config = self._load_oci_config(config_path, profile)
        
        # Initialize OCI clients
        self.compute_client = ComputeClient(self.config)
        self.blockstorage_client = BlockstorageClient(self.config)
        self.virtual_network_client = VirtualNetworkClient(self.config)
        self.database_client = DatabaseClient(self.config)
        self.load_balancer_client = LoadBalancerClient(self.config)
        self.identity_client = IdentityClient(self.config)
        
        # Define cost optimization criteria
        self.production_db_shapes = [
            'VM.Standard2.2', 'VM.Standard2.4', 'VM.Standard2.8', 'VM.Standard2.16', 'VM.Standard2.24',
            'VM.Standard3.2', 'VM.Standard3.4', 'VM.Standard3.8', 'VM.Standard3.16', 'VM.Standard3.24',
            'BM.Standard2.52', 'BM.Standard3.64', 'BM.HighIO1.36',
            'VM.Standard.E3.2', 'VM.Standard.E3.4', 'VM.Standard.E3.8'
        ]
        
        self.oversized_compute_shapes = [
            'VM.Standard2.2', 'VM.Standard2.4', 'VM.Standard2.8', 'VM.Standard2.16', 'VM.Standard2.24',
            'VM.Standard3.2', 'VM.Standard3.4', 'VM.Standard3.8', 'VM.Standard3.16', 'VM.Standard3.24',
            'VM.DenseIO2.8', 'VM.DenseIO2.16', 'VM.DenseIO2.24',
            'VM.GPU3.1', 'VM.GPU3.2', 'VM.GPU3.4',
            'BM.Standard2.52', 'BM.Standard3.64'
        ]
        
        self.dev_test_tags = ['dev', 'test', 'development', 'testing', 'staging', 'qa']
        self.automation_tag_keys = ['auto-shutdown', 'auto-start', 'schedule', 'stop-start', 'automation']
        
        self.logger.info("🍳 CloudCostChefs OCI Dev/Test Cost Chef initialized")

    def _setup_logging(self) -> logging.Logger:
        """Set up logging configuration."""
        logging.basicConfig(
            level=logging.INFO,
            format='[%(asctime)s] [%(levelname)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        return logging.getLogger(__name__)

    def _load_oci_config(self, config_path: str = None, profile: str = None) -> dict:
        """Load OCI configuration from file or default location."""
        try:
            if config_path:
                config = from_file(config_path, profile or "DEFAULT")
            else:
                config = from_file(profile_name=profile or "DEFAULT")
            
            self.logger.info(f"OCI config loaded for tenancy: {config.get('tenancy', 'Unknown')[:20]}...")
            return config
        except Exception as e:
            self.logger.error(f"Failed to load OCI config: {str(e)}")
            self.logger.error("Please configure OCI CLI with 'oci setup config' or provide valid config file")
            sys.exit(1)

    def get_compartments(self, compartment_ids: List[str] = None) -> List[Dict[str, str]]:
        """Get list of compartments to check."""
        if compartment_ids:
            compartments = []
            for comp_id in compartment_ids:
                try:
                    comp = self.identity_client.get_compartment(comp_id).data
                    compartments.append({
                        'id': comp.id,
                        'name': comp.name,
                        'lifecycle_state': comp.lifecycle_state
                    })
                except Exception as e:
                    self.logger.warning(f"Could not access compartment {comp_id}: {str(e)}")
            return compartments
        else:
            # Use root compartment (tenancy)
            tenancy_id = self.config['tenancy']
            try:
                tenancy = self.identity_client.get_compartment(tenancy_id).data
                return [{
                    'id': tenancy.id,
                    'name': tenancy.name,
                    'lifecycle_state': tenancy.lifecycle_state
                }]
            except Exception as e:
                self.logger.error(f"Could not access root compartment: {str(e)}")
                return []

    def is_dev_test_resource(self, resource_tags: Dict[str, Any]) -> bool:
        """Check if resource has dev/test tags."""
        if not resource_tags:
            return False
        
        # Check freeform tags
        if hasattr(resource_tags, 'freeform_tags') and resource_tags.freeform_tags:
            for key, value in resource_tags.freeform_tags.items():
                if value.lower() in self.dev_test_tags:
                    return True
        
        # Check defined tags
        if hasattr(resource_tags, 'defined_tags') and resource_tags.defined_tags:
            for namespace, tags in resource_tags.defined_tags.items():
                for key, value in tags.items():
                    if value.lower() in self.dev_test_tags:
                        return True
        
        return False

    def has_automation_tags(self, resource_tags: Dict[str, Any]) -> bool:
        """Check if resource has automation tags."""
        if not resource_tags:
            return False
        
        # Check freeform tags
        if hasattr(resource_tags, 'freeform_tags') and resource_tags.freeform_tags:
            for key in resource_tags.freeform_tags.keys():
                for auto_key in self.automation_tag_keys:
                    if auto_key.lower() in key.lower():
                        return True
        
        # Check defined tags
        if hasattr(resource_tags, 'defined_tags') and resource_tags.defined_tags:
            for namespace, tags in resource_tags.defined_tags.items():
                for key in tags.keys():
                    for auto_key in self.automation_tag_keys:
                        if auto_key.lower() in key.lower():
                            return True
        
        return False

    def format_tags(self, resource_tags: Dict[str, Any]) -> str:
        """Format tags for display."""
        tag_strings = []
        
        if hasattr(resource_tags, 'freeform_tags') and resource_tags.freeform_tags:
            for key, value in resource_tags.freeform_tags.items():
                tag_strings.append(f"{key}={value}")
        
        if hasattr(resource_tags, 'defined_tags') and resource_tags.defined_tags:
            for namespace, tags in resource_tags.defined_tags.items():
                for key, value in tags.items():
                    tag_strings.append(f"{namespace}.{key}={value}")
        
        return '; '.join(tag_strings) if tag_strings else 'N/A'

    def check_database_instances(self, compartment_id: str) -> List[Dict[str, Any]]:
        """Check database instances for production-grade shapes."""
        results = []
        
        try:
            self.logger.info(f"Checking database instances in compartment: {compartment_id}")
            
            # Check DB Systems
            db_systems = self.database_client.list_db_systems(compartment_id=compartment_id).data
            for db_system in db_systems:
                if (self.is_dev_test_resource(db_system) and 
                    db_system.shape in self.production_db_shapes and
                    db_system.lifecycle_state == 'AVAILABLE'):
                    
                    results.append({
                        'resource_type': 'DB System',
                        'name': db_system.display_name,
                        'shape': db_system.shape,
                        'lifecycle_state': db_system.lifecycle_state,
                        'availability_domain': db_system.availability_domain,
                        'cpu_core_count': getattr(db_system, 'cpu_core_count', 'N/A'),
                        'database_edition': getattr(db_system, 'database_edition', 'N/A'),
                        'compartment_id': compartment_id,
                        'tags': self.format_tags(db_system),
                        'resource_id': db_system.id
                    })
            
            # Check Autonomous Databases
            autonomous_dbs = self.database_client.list_autonomous_databases(compartment_id=compartment_id).data
            for adb in autonomous_dbs:
                if (self.is_dev_test_resource(adb) and 
                    adb.cpu_core_count >= 4 and  # Consider 4+ cores as production-grade
                    adb.lifecycle_state == 'AVAILABLE'):
                    
                    results.append({
                        'resource_type': 'Autonomous Database',
                        'name': adb.display_name,
                        'shape': f"{adb.cpu_core_count} OCPUs",
                        'lifecycle_state': adb.lifecycle_state,
                        'availability_domain': 'N/A',
                        'cpu_core_count': adb.cpu_core_count,
                        'database_edition': getattr(adb, 'db_workload', 'N/A'),
                        'compartment_id': compartment_id,
                        'tags': self.format_tags(adb),
                        'resource_id': adb.id
                    })
                    
        except Exception as e:
            self.logger.warning(f"Error checking database instances: {str(e)}")
        
        return results

    def check_compute_instances(self, compartment_id: str) -> tuple:
        """Check compute instances for missing automation tags and oversized shapes."""
        missing_automation = []
        oversized_instances = []
        
        try:
            self.logger.info(f"Checking compute instances in compartment: {compartment_id}")
            
            instances = self.compute_client.list_instances(compartment_id=compartment_id).data
            for instance in instances:
                if (self.is_dev_test_resource(instance) and 
                    instance.lifecycle_state in ['RUNNING', 'STOPPED']):
                    
                    # Check for missing automation tags
                    if not self.has_automation_tags(instance):
                        missing_automation.append({
                            'instance_name': instance.display_name,
                            'shape': instance.shape,
                            'lifecycle_state': instance.lifecycle_state,
                            'availability_domain': instance.availability_domain,
                            'time_created': instance.time_created.strftime("%Y-%m-%d %H:%M:%S"),
                            'compartment_id': compartment_id,
                            'tags': self.format_tags(instance),
                            'resource_id': instance.id
                        })
                    
                    # Check for oversized instances
                    if instance.shape in self.oversized_compute_shapes:
                        oversized_instances.append({
                            'instance_name': instance.display_name,
                            'shape': instance.shape,
                            'lifecycle_state': instance.lifecycle_state,
                            'availability_domain': instance.availability_domain,
                            'time_created': instance.time_created.strftime("%Y-%m-%d %H:%M:%S"),
                            'compartment_id': compartment_id,
                            'tags': self.format_tags(instance),
                            'resource_id': instance.id
                        })
                        
        except Exception as e:
            self.logger.warning(f"Error checking compute instances: {str(e)}")
        
        return missing_automation, oversized_instances

    def check_unattached_volumes(self, compartment_id: str) -> List[Dict[str, Any]]:
        """Check for unattached block volumes."""
        results = []
        
        try:
            self.logger.info(f"Checking block volumes in compartment: {compartment_id}")
            
            volumes = self.blockstorage_client.list_volumes(compartment_id=compartment_id).data
            for volume in volumes:
                if (self.is_dev_test_resource(volume) and 
                    volume.lifecycle_state == 'AVAILABLE'):
                    
                    # Check if volume is attached
                    attachments = self.compute_client.list_volume_attachments(
                        compartment_id=compartment_id,
                        volume_id=volume.id
                    ).data
                    
                    if not attachments:
                        results.append({
                            'volume_name': volume.display_name,
                            'size_gb': volume.size_in_gbs,
                            'volume_type': getattr(volume, 'vpus_per_gb', 'Standard'),
                            'availability_domain': volume.availability_domain,
                            'lifecycle_state': volume.lifecycle_state,
                            'time_created': volume.time_created.strftime("%Y-%m-%d %H:%M:%S"),
                            'compartment_id': compartment_id,
                            'tags': self.format_tags(volume),
                            'resource_id': volume.id
                        })
                        
        except Exception as e:
            self.logger.warning(f"Error checking block volumes: {str(e)}")
        
        return results

    def check_unused_public_ips(self, compartment_id: str) -> List[Dict[str, Any]]:
        """Check for unused public IP addresses."""
        results = []
        
        try:
            self.logger.info(f"Checking public IPs in compartment: {compartment_id}")
            
            public_ips = self.virtual_network_client.list_public_ips(
                scope='REGION',
                compartment_id=compartment_id
            ).data
            
            for public_ip in public_ips:
                if (self.is_dev_test_resource(public_ip) and 
                    public_ip.lifecycle_state == 'AVAILABLE' and
                    not public_ip.assigned_entity_id):
                    
                    results.append({
                        'public_ip_name': public_ip.display_name,
                        'ip_address': public_ip.ip_address,
                        'scope': public_ip.scope,
                        'lifetime': public_ip.lifetime,
                        'lifecycle_state': public_ip.lifecycle_state,
                        'time_created': public_ip.time_created.strftime("%Y-%m-%d %H:%M:%S"),
                        'compartment_id': compartment_id,
                        'tags': self.format_tags(public_ip),
                        'resource_id': public_ip.id
                    })
                    
        except Exception as e:
            self.logger.warning(f"Error checking public IPs: {str(e)}")
        
        return results

    def check_empty_load_balancers(self, compartment_id: str) -> List[Dict[str, Any]]:
        """Check for load balancers with no backends."""
        results = []
        
        try:
            self.logger.info(f"Checking load balancers in compartment: {compartment_id}")
            
            load_balancers = self.load_balancer_client.list_load_balancers(compartment_id=compartment_id).data
            for lb in load_balancers:
                if (self.is_dev_test_resource(lb) and 
                    lb.lifecycle_state == 'ACTIVE'):
                    
                    # Get backend sets
                    lb_details = self.load_balancer_client.get_load_balancer(lb.id).data
                    has_backends = False
                    
                    if lb_details.backend_sets:
                        for backend_set_name, backend_set in lb_details.backend_sets.items():
                            if backend_set.backends:
                                has_backends = True
                                break
                    
                    if not has_backends:
                        results.append({
                            'load_balancer_name': lb.display_name,
                            'shape': lb.shape_name,
                            'lifecycle_state': lb.lifecycle_state,
                            'ip_addresses': '; '.join([ip.ip_address for ip in lb.ip_addresses]),
                            'time_created': lb.time_created.strftime("%Y-%m-%d %H:%M:%S"),
                            'compartment_id': compartment_id,
                            'tags': self.format_tags(lb),
                            'resource_id': lb.id
                        })
                        
        except Exception as e:
            self.logger.warning(f"Error checking load balancers: {str(e)}")
        
        return results

    def check_permissive_security_lists(self, compartment_id: str) -> List[Dict[str, Any]]:
        """Check for overly permissive security lists."""
        results = []
        
        try:
            self.logger.info(f"Checking security lists in compartment: {compartment_id}")
            
            # Get VCNs first
            vcns = self.virtual_network_client.list_vcns(compartment_id=compartment_id).data
            
            for vcn in vcns:
                if vcn.lifecycle_state == 'AVAILABLE':
                    security_lists = self.virtual_network_client.list_security_lists(
                        compartment_id=compartment_id,
                        vcn_id=vcn.id
                    ).data
                    
                    for sec_list in security_lists:
                        if (self.is_dev_test_resource(sec_list) and 
                            sec_list.lifecycle_state == 'AVAILABLE'):
                            
                            permissive_rules = []
                            
                            # Check ingress rules
                            for rule in sec_list.ingress_security_rules:
                                if (rule.source == '0.0.0.0/0' and 
                                    (not rule.tcp_options or 
                                     (rule.tcp_options.destination_port_range and 
                                      (rule.tcp_options.destination_port_range.min == 22 or 
                                       rule.tcp_options.destination_port_range.min == 3389)))):
                                    permissive_rules.append(f"TCP:{rule.tcp_options.destination_port_range.min if rule.tcp_options and rule.tcp_options.destination_port_range else 'ALL'}")
                            
                            if permissive_rules:
                                results.append({
                                    'security_list_name': sec_list.display_name,
                                    'vcn_name': vcn.display_name,
                                    'lifecycle_state': sec_list.lifecycle_state,
                                    'permissive_rules_count': len(permissive_rules),
                                    'permissive_rules': '; '.join(permissive_rules),
                                    'compartment_id': compartment_id,
                                    'tags': self.format_tags(sec_list),
                                    'resource_id': sec_list.id
                                })
                                
        except Exception as e:
            self.logger.warning(f"Error checking security lists: {str(e)}")
        
        return results

    def analyze_compartment(self, compartment_id: str) -> Dict[str, List[Dict[str, Any]]]:
        """Analyze a single compartment for cost optimization opportunities."""
        results = {
            'database_instances': [],
            'compute_missing_automation': [],
            'oversized_compute': [],
            'unattached_volumes': [],
            'unused_public_ips': [],
            'empty_load_balancers': [],
            'permissive_security_lists': []
        }
        
        # Check database instances
        results['database_instances'] = self.check_database_instances(compartment_id)
        
        # Check compute instances
        missing_auto, oversized = self.check_compute_instances(compartment_id)
        results['compute_missing_automation'] = missing_auto
        results['oversized_compute'] = oversized
        
        # Check unattached volumes
        results['unattached_volumes'] = self.check_unattached_volumes(compartment_id)
        
        # Check unused public IPs
        results['unused_public_ips'] = self.check_unused_public_ips(compartment_id)
        
        # Check empty load balancers
        results['empty_load_balancers'] = self.check_empty_load_balancers(compartment_id)
        
        # Check permissive security lists
        results['permissive_security_lists'] = self.check_permissive_security_lists(compartment_id)
        
        return results

    def export_to_csv(self, results: Dict[str, List[Dict[str, Any]]], output_path: str) -> List[str]:
        """Export results to CSV files."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        csv_files = []
        
        report_mappings = {
            'database_instances': 'Database_Production_Shapes',
            'compute_missing_automation': 'Compute_Missing_Automation_Tags',
            'oversized_compute': 'Oversized_Compute_Instances',
            'unattached_volumes': 'Unattached_Block_Volumes',
            'unused_public_ips': 'Unused_Public_IPs',
            'empty_load_balancers': 'Empty_Load_Balancers',
            'permissive_security_lists': 'Permissive_Security_Lists'
        }
        
        for category, data in results.items():
            if data:
                filename = os.path.join(output_path, f"{report_mappings[category]}_{timestamp}.csv")
                
                with open(filename, 'w', newline='', encoding='utf-8') as csvfile:
                    if data:
                        fieldnames = data[0].keys()
                        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
                        writer.writeheader()
                        writer.writerows(data)
                        
                csv_files.append(filename)
                self.logger.info(f"CSV report saved to: {filename}")
        
        return csv_files

    def generate_html_report(self, all_results: Dict[str, List[Dict[str, Any]]], 
                           output_path: str) -> str:
        """Generate HTML report."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = os.path.join(output_path, f"OCI_DevTest_Resource_Report_{timestamp}.html")
        
        report_timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        # Calculate totals
        total_counts = {k: len(v) for k, v in all_results.items()}
        total_issues = sum(total_counts.values())
        
        html_content = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>OCI Dev/Test Resource Cost Chef Report</title>
    <style>
        body {{ 
            font-family: 'Oracle Sans', 'Helvetica Neue', Arial, sans-serif; 
            margin: 20px; 
            background-color: #f7f7f7; 
        }}
        .container {{ 
            background-color: white; 
            padding: 30px; 
            border-radius: 8px; 
            box-shadow: 0 2px 8px rgba(0,0,0,0.1); 
        }}
        h1, h2 {{ color: #312d2a; }}
        h1 {{ border-bottom: 3px solid #ff4800; padding-bottom: 10px; }}
        table {{ 
            border-collapse: collapse; 
            width: 100%; 
            margin-bottom: 30px; 
        }}
        th, td {{ 
            border: 1px solid #e0e0e0; 
            padding: 12px; 
            text-align: left; 
        }}
        th {{ 
            background: linear-gradient(135deg, #312d2a 0%, #ff4800 100%); 
            color: white; 
            font-weight: bold; 
        }}
        tr:nth-child(even) {{ background-color: #fafafa; }}
        tr:hover {{ background-color: #fff3e0; }}
        .summary {{ 
            background: linear-gradient(135deg, #ff4800 0%, #ff6800 100%); 
            color: white; 
            padding: 20px; 
            border-radius: 8px; 
            margin-bottom: 20px; 
        }}
        .warning {{ color: #d32f2f; font-weight: bold; }}
        .timestamp {{ color: #666; font-size: 0.9em; }}
        .footer {{ 
            margin-top: 30px; 
            padding-top: 20px; 
            border-top: 1px solid #e0e0e0; 
            text-align: center; 
            color: #666; 
        }}
        .metric {{ font-weight: bold; font-size: 1.1em; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>🍳 OCI Dev/Test Resource Cost Chef Report</h1>
        <div class="timestamp">Generated on: {report_timestamp}</div>
        
        <div class='summary'>
            <h3 style="margin-top: 0; color: white;">🔍 Cost Optimization Opportunities</h3>
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px;">
                <div>📊 Database Production Shapes: <span class="metric">{total_counts['database_instances']}</span></div>
                <div>🚦 Compute Missing Auto-Tags: <span class="metric">{total_counts['compute_missing_automation']}</span></div>
                <div>🍖 Oversized Compute Instances: <span class="metric">{total_counts['oversized_compute']}</span></div>
                <div>💽 Unattached Block Volumes: <span class="metric">{total_counts['unattached_volumes']}</span></div>
                <div>🌐 Unused Public IPs: <span class="metric">{total_counts['unused_public_ips']}</span></div>
                <div>⚖️ Empty Load Balancers: <span class="metric">{total_counts['empty_load_balancers']}</span></div>
                <div>🔓 Permissive Security Lists: <span class="metric">{total_counts['permissive_security_lists']}</span></div>
            </div>
        </div>

        <h2>🗄️ Database Instances Using Production-Grade Shapes</h2>"""
        
        if all_results['database_instances']:
            html_content += """<table>
                <tr>
                    <th>Resource Type</th><th>Name</th><th>Shape</th><th>State</th>
                    <th>Availability Domain</th><th>CPU Cores</th><th>Tags</th>
                </tr>"""
            for db in all_results['database_instances']:
                html_content += f"""<tr>
                    <td>{db['resource_type']}</td>
                    <td>{db['name']}</td>
                    <td class='warning'>{db['shape']}</td>
                    <td>{db['lifecycle_state']}</td>
                    <td>{db['availability_domain']}</td>
                    <td>{db['cpu_core_count']}</td>
                    <td>{db['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ Excellent! All dev/test database instances are using appropriate shapes.</p>"

        html_content += "<h2>🖥️ Compute Instances Missing Automation Tags</h2>"
        
        if all_results['compute_missing_automation']:
            html_content += """<table>
                <tr>
                    <th>Instance Name</th><th>Shape</th><th>State</th>
                    <th>Availability Domain</th><th>Created</th><th>Tags</th>
                </tr>"""
            for instance in all_results['compute_missing_automation']:
                html_content += f"""<tr>
                    <td>{instance['instance_name']}</td>
                    <td>{instance['shape']}</td>
                    <td>{instance['lifecycle_state']}</td>
                    <td>{instance['availability_domain']}</td>
                    <td>{instance['time_created']}</td>
                    <td>{instance['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ All dev/test compute instances have automation tags configured!</p>"

        html_content += "<h2>🍖 Oversized Compute Instances for Dev/Test</h2>"
        
        if all_results['oversized_compute']:
            html_content += """<table>
                <tr>
                    <th>Instance Name</th><th>Shape</th><th>State</th>
                    <th>Availability Domain</th><th>Created</th><th>Tags</th>
                </tr>"""
            for instance in all_results['oversized_compute']:
                html_content += f"""<tr>
                    <td>{instance['instance_name']}</td>
                    <td class='warning'>{instance['shape']}</td>
                    <td>{instance['lifecycle_state']}</td>
                    <td>{instance['availability_domain']}</td>
                    <td>{instance['time_created']}</td>
                    <td>{instance['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ No oversized compute instances found in dev/test environments!</p>"

        html_content += "<h2>💽 Unattached Block Volumes</h2>"
        
        if all_results['unattached_volumes']:
            html_content += """<table>
                <tr>
                    <th>Volume Name</th><th>Size (GB)</th><th>Type</th>
                    <th>Availability Domain</th><th>Created</th><th>Tags</th>
                </tr>"""
            for volume in all_results['unattached_volumes']:
                html_content += f"""<tr>
                    <td>{volume['volume_name']}</td>
                    <td>{volume['size_gb']}</td>
                    <td>{volume['volume_type']}</td>
                    <td>{volume['availability_domain']}</td>
                    <td>{volume['time_created']}</td>
                    <td>{volume['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ No unattached block volumes found!</p>"

        html_content += "<h2>🌐 Unused Public IP Addresses</h2>"
        
        if all_results['unused_public_ips']:
            html_content += """<table>
                <tr>
                    <th>Public IP Name</th><th>IP Address</th><th>Scope</th>
                    <th>Lifetime</th><th>Created</th><th>Tags</th>
                </tr>"""
            for ip in all_results['unused_public_ips']:
                html_content += f"""<tr>
                    <td>{ip['public_ip_name']}</td>
                    <td>{ip['ip_address']}</td>
                    <td>{ip['scope']}</td>
                    <td>{ip['lifetime']}</td>
                    <td>{ip['time_created']}</td>
                    <td>{ip['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ No unused public IP addresses found!</p>"

        html_content += "<h2>⚖️ Load Balancers with No Backends</h2>"
        
        if all_results['empty_load_balancers']:
            html_content += """<table>
                <tr>
                    <th>Load Balancer Name</th><th>Shape</th><th>State</th>
                    <th>IP Addresses</th><th>Created</th><th>Tags</th>
                </tr>"""
            for lb in all_results['empty_load_balancers']:
                html_content += f"""<tr>
                    <td>{lb['load_balancer_name']}</td>
                    <td>{lb['shape']}</td>
                    <td>{lb['lifecycle_state']}</td>
                    <td>{lb['ip_addresses']}</td>
                    <td>{lb['time_created']}</td>
                    <td>{lb['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ All load balancers have active backends!</p>"

        html_content += "<h2>🔓 Permissive Security Lists</h2>"
        
        if all_results['permissive_security_lists']:
            html_content += """<table>
                <tr>
                    <th>Security List Name</th><th>VCN Name</th><th>Permissive Rules</th>
                    <th>Rule Details</th><th>Tags</th>
                </tr>"""
            for sec_list in all_results['permissive_security_lists']:
                html_content += f"""<tr>
                    <td>{sec_list['security_list_name']}</td>
                    <td>{sec_list['vcn_name']}</td>
                    <td class='warning'>{sec_list['permissive_rules_count']}</td>
                    <td class='warning'>{sec_list['permissive_rules']}</td>
                    <td>{sec_list['tags']}</td>
                </tr>"""
            html_content += "</table>"
        else:
            html_content += "<p>✅ No overly permissive security lists found!</p>"

        html_content += f"""
        <h2>🍽️ Chef's OCI Cost-Saving Recommendations</h2>
        <ul>
            <li><strong>🔽 Database Right-Sizing:</strong> Switch to VM.Standard2.1, VM.Standard.E2.1, or Always Free Autonomous DB for dev/test—production power isn't needed for testing recipes.</li>
            <li><strong>⏱️ Compute Auto-Shutdown:</strong> Tag instances with automation schedules to stop after hours—your OCI bill will thank you for turning off the oven.</li>
            <li><strong>📏 Compute Right-Sizing:</strong> Use VM.Standard.E2.1.Micro, VM.Standard2.1, or Always Free shapes for dev/test—no need for large servings when a small plate will do.</li>
            <li><strong>💽 Block Volume Cleanup:</strong> Delete unattached volumes—these orphaned ingredients are still charging you storage fees.</li>
            <li><strong>🌐 Release Public IPs:</strong> Return unused public IPs to OCI—each idle IP costs money when not attached to resources.</li>
            <li><strong>⚖️ Load Balancer Cleanup:</strong> Remove load balancers with no backends—empty serving trays cost money without providing value.</li>
            <li><strong>🔒 Security List Tightening:</strong> Close unnecessary 0.0.0.0/0 rules—keep your dev kitchen secure without leaving doors wide open.</li>
            <li><strong>💰 Always Free Resources:</strong> Use OCI Always Free tier for long-running dev/test workloads—it's like getting free ingredients forever!</li>
            <li><strong>📊 Cost Budgets:</strong> Set up OCI Budget alerts to catch cost spikes before they burn your wallet.</li>
            <li><strong>🏷️ Preemptible Instances:</strong> Use preemptible compute for fault-tolerant dev/test workloads to save up to 50%.</li>
        </ul>
        
        <div class='footer'>
            <p>Generated on {report_timestamp}</p>
            <p>🍳 CloudCostChefs - Serving up OCI savings, one resource at a time</p>
        </div>
    </div>
</body>
</html>"""
        
        with open(filename, 'w', encoding='utf-8') as f:
            f.write(html_content)
        
        self.logger.info(f"HTML report saved to: {filename}")
        return filename


def main():
    parser = argparse.ArgumentParser(
        description='🍳 CloudCostChefs: OCI Dev/Test Resource Cost Chef',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python oci_devtest_cost_chef.py --output-path ./reports
    python oci_devtest_cost_chef.py --compartments ocid1.compartment.oc1..xxx,ocid1.compartment.oc1..yyy
    python oci_devtest_cost_chef.py --config-path ~/.oci/config --profile PROD
        """
    )
    
    parser.add_argument('--output-path', type=str, default='.',
                       help='Path to store CSV and HTML reports (default: current directory)')
    parser.add_argument('--compartments', type=str,
                       help='Comma-separated list of compartment OCIDs to check')
    parser.add_argument('--config-path', type=str,
                       help='Path to OCI config file (default: ~/.oci/config)')
    parser.add_argument('--profile', type=str,
                       help='OCI config profile to use (default: DEFAULT)')
    parser.add_argument('--verbose', action='store_true',
                       help='Enable debug logging')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Parse compartment IDs if provided
    compartment_ids = None
    if args.compartments:
        compartment_ids = [c.strip() for c in args.compartments.split(',')]
    
    try:
        # Initialize cost chef
        chef = OCIDevTestCostChef(args.config_path, args.profile)
        
        # Get compartments to analyze
        compartments = chef.get_compartments(compartment_ids)
        if not compartments:
            chef.logger.error("No accessible compartments found")
            sys.exit(1)
        
        chef.logger.info(f"Will check compartments: {[c['name'] for c in compartments]}")
        
        # Aggregate results from all compartments
        all_results = {
            'database_instances': [],
            'compute_missing_automation': [],
            'oversized_compute': [],
            'unattached_volumes': [],
            'unused_public_ips': [],
            'empty_load_balancers': [],
            'permissive_security_lists': []
        }
        
        for compartment in compartments:
            if compartment['lifecycle_state'] != 'ACTIVE':
                chef.logger.warning(f"Skipping inactive compartment: {compartment['name']}")
                continue
                
            chef.logger.info(f"Processing compartment: {compartment['name']}")
            
            comp_results = chef.analyze_compartment(compartment['id'])
            
            # Merge results
            for category, results in comp_results.items():
                all_results[category].extend(results)
        
        # Calculate totals
        total_issues = sum(len(results) for results in all_results.values())
        
        if total_issues > 0:
            # Export to CSV
            csv_files = chef.export_to_csv(all_results, args.output_path)
            
            # Generate HTML report
            html_file = chef.generate_html_report(all_results, args.output_path)
            
            # Try to open HTML report
            try:
                webbrowser.open(f'file://{os.path.abspath(html_file)}')
                chef.logger.info("Opening HTML report in default browser...")
            except Exception:
                chef.logger.warning(f"Could not auto-open HTML report. Please open manually: {html_file}")
        else:
            chef.logger.info("No cost optimization opportunities found in dev/test resources.")
        
        # Summary output
        chef.logger.info("🍳 OCI Dev/Test Cost Analysis Complete!")
        chef.logger.info("Summary:")
        chef.logger.info(f"- Database instances with production shapes: {len(all_results['database_instances'])}")
        chef.logger.info(f"- Compute instances missing automation tags: {len(all_results['compute_missing_automation'])}")
        chef.logger.info(f"- Oversized compute instances: {len(all_results['oversized_compute'])}")
        chef.logger.info(f"- Unattached block volumes: {len(all_results['unattached_volumes'])}")
        chef.logger.info(f"- Unused public IP addresses: {len(all_results['unused_public_ips'])}")
        chef.logger.info(f"- Empty load balancers: {len(all_results['empty_load_balancers'])}")
        chef.logger.info(f"- Permissive security lists: {len(all_results['permissive_security_lists'])}")
        
        if total_issues > 0:
            chef.logger.info(f"Total cost optimization opportunities found: {total_issues}")
            chef.logger.info("Chef's Tip: Review the detailed reports and start cooking up some serious OCI savings!")
        else:
            chef.logger.info("🎉 Your OCI dev/test kitchen is perfectly optimized—no waste detected!")
        
    except KeyboardInterrupt:
        print("\n❌ Operation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
