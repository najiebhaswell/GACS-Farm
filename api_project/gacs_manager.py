#!/usr/bin/env python3
"""
GACS Manager Module - Python implementation for Docker orchestration
Replaces bash script with Python functions for API integration
"""

import os
import subprocess
import json
import random
import string
import re
import socket
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import yaml

# Configuration
MAIN_DIR = Path(__file__).parent.parent
INSTANCES_DIR = MAIN_DIR / "instances"
SOURCE_DIR = MAIN_DIR / "source"
MANAGER_DIR = MAIN_DIR / "manager"
LOG_FILE = MANAGER_DIR / "log.txt"
CONFIG_FILE = MANAGER_DIR / "config.conf"
NGINX_DIR = MANAGER_DIR / "nginx"
NGINX_CONF_DIR = NGINX_DIR / "conf.d"
SSL_DIR = NGINX_DIR / "ssl"
PARAM_DIR = SOURCE_DIR / "GACS-Ubuntu-22.04" / "parameter"

# Create directories
for d in [INSTANCES_DIR, NGINX_CONF_DIR, SSL_DIR]:
    d.mkdir(parents=True, exist_ok=True)


class GACSManager:
    """GenieACS Management System - Python Implementation"""
    
    def __init__(self):
        self.docker_compose_cmd = None
        try:
            self.docker_compose_cmd = self._get_docker_compose_cmd()
        except RuntimeError:
            pass  # Docker not available, will be checked when needed
        
    def _get_docker_compose_cmd(self) -> str:
        """Detect docker compose command (v2 plugin or v1 standalone)"""
        try:
            subprocess.run(["docker", "compose", "version"], 
                         capture_output=True, check=True)
            return "docker compose"
        except (subprocess.CalledProcessError, FileNotFoundError):
            try:
                subprocess.run(["docker-compose", "--version"], 
                             capture_output=True, check=True)
                return "docker-compose"
            except (subprocess.CalledProcessError, FileNotFoundError):
                raise RuntimeError("Docker Compose not installed")
    
    def _log_action(self, action: str, message: str):
        """Log action to file"""
        from datetime import datetime
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        with open(LOG_FILE, 'a') as f:
            f.write(f"[{timestamp}] [{action}] {message}\n")
    
    def _check_dependencies(self) -> bool:
        """Check if required dependencies are installed"""
        required = ['docker', 'curl', 'git']
        for cmd in required:
            try:
                subprocess.run([cmd, '--version'], 
                             capture_output=True, check=True)
            except (subprocess.CalledProcessError, FileNotFoundError):
                raise RuntimeError(f"Dependency missing: {cmd}")
        
        # Check docker compose
        self._get_docker_compose_cmd()
        return True
    
    def _get_random_free_port(self) -> int:
        """Find a random free port between 1000-9999"""
        while True:
            port = random.randint(1000, 9999)
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                try:
                    s.bind(('0.0.0.0', port))
                    return port
                except OSError:
                    continue
    
    def _generate_random_password(self, length: int = 16) -> str:
        """Generate random password"""
        chars = string.ascii_letters + string.digits
        return ''.join(random.choice(chars) for _ in range(length))
    
    def _get_public_ip(self) -> str:
        """Get public IP address"""
        try:
            result = subprocess.run(
                ['curl', '-s', 'https://api.ipify.org'],
                capture_output=True, text=True, timeout=5
            )
            return result.stdout.strip()
        except Exception:
            return "UNKNOWN"
    
    def _load_config(self) -> Dict:
        """Load configuration file"""
        config = {}
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, 'r') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        config[key] = value.strip('"\'')
        return config
    
    def _allocate_vpn_tun_pool(self) -> str:
        """Allocate unique VPN tunnel pool base"""
        return f"10.{random.randint(100, 200)}.{random.randint(0, 254)}"
    
    def _create_docker_network(self, network_name: str = "gacs-radius-net"):
        """Create global Docker network for RADIUS integration"""
        try:
            subprocess.run(
                ['docker', 'network', 'ls', '--format', '{{.Name}}'],
                capture_output=True, text=True, check=True
            )
            # Check if network exists
            result = subprocess.run(
                ['docker', 'network', 'ls', '--format', '{{.Name}}'],
                capture_output=True, text=True
            )
            if network_name not in result.stdout:
                subprocess.run(
                    ['docker', 'network', 'create', network_name],
                    capture_output=True, check=True
                )
                self._log_action("NETWORK", f"Created global network '{network_name}'")
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Failed to create Docker network: {e}")
    
    def create_customer_instance(
        self,
        instance_name: str,
        version: str = "stable",
        onu_subnet: str = "",
        base_domain: Optional[str] = None,
        ssl_enabled: bool = False
    ) -> Dict:
        """
        Create new customer instance with GenieACS and OpenVPN
        
        Args:
            instance_name: Unique instance name (alphanumeric, dash, underscore)
            version: GenieACS version ("stable" or "latest")
            onu_subnet: ONU subnet(s) comma-separated (e.g., "10.50.0.0/16")
            base_domain: Optional domain for subdomain routing
            ssl_enabled: Enable SSL via Cloudflare
            
        Returns:
            Dict with instance details and connection info
        """
        # Check Docker availability
        if not self.docker_compose_cmd:
            try:
                self.docker_compose_cmd = self._get_docker_compose_cmd()
            except RuntimeError as e:
                raise RuntimeError(f"Docker not available: {e}")
        
        # Validate instance name
        if not re.match(r'^[a-zA-Z0-9_-]+$', instance_name):
            raise ValueError("Invalid instance name. Use only letters, numbers, dash, underscore")
        
        target_dir = INSTANCES_DIR / instance_name
        if target_dir.exists():
            raise ValueError(f"Instance '{instance_name}' already exists")
        
        # Check source availability
        version_path = SOURCE_DIR / version / "package.json"
        if not version_path.exists():
            raise RuntimeError(f"GenieACS source '{version}' not available. Run setup first.")
        
        self._log_action("INSTALL", f"START - '{instance_name}' ver={version}")
        
        # Allocate ports
        ports = {
            'cwmp': self._get_random_free_port(),
            'nbi': self._get_random_free_port(),
            'fs': self._get_random_free_port(),
            'ui': self._get_random_free_port(),
            'openvpn': self._get_random_free_port()
        }
        
        # Generate Docker subnet
        docker_subnet = f"10.{random.randint(10, 209)}.{random.randint(0, 249)}"
        
        # Allocate VPN pool
        vpn_pool_base = self._allocate_vpn_tun_pool()
        
        # Create target directory
        target_dir.mkdir(parents=True, exist_ok=True)
        
        # Create global network
        self._create_docker_network()
        
        # Prepare VPN environment
        vpn_env = {
            'VPN_PORT': str(ports['openvpn']),
            'VPN_PROTO': 'udp'
        }
        if base_domain:
            vpn_env['VPN_DNS_NAME'] = f"acs-{instance_name}.{base_domain}"
        
        vpn_env_file = target_dir / "vpn.env"
        with open(vpn_env_file, 'w') as f:
            for key, value in vpn_env.items():
                f.write(f"{key}={value}\n")
        
        # Build route commands for ONU subnets
        onu_subnets = [s.strip() for s in onu_subnet.split(',')] if onu_subnet else []
        route_commands = []
        for subnet in onu_subnets:
            route_commands.append(f"ip route add {subnet} via {docker_subnet}.254")
        common_route_cmd = " && ".join(route_commands) if route_commands else ""
        if common_route_cmd:
            common_route_cmd += " && "
        
        # Generate docker-compose.yml
        compose_data = {
            'version': '3.8',
            'services': {
                'openvpn': {
                    'image': 'hwdsl2/openvpn-server',
                    'container_name': f'ovpn-{instance_name}',
                    'restart': 'always',
                    'ports': [f"{ports['openvpn']}:{ports['openvpn']}/udp"],
                    'volumes': [
                        './ovpn-data:/etc/openvpn',
                        './vpn.env:/vpn.env:ro'
                    ],
                    'cap_add': ['NET_ADMIN'],
                    'devices': ['/dev/net/tun:/dev/net/tun'],
                    'sysctls': [
                        'net.ipv4.ip_forward=1',
                        'net.ipv6.conf.all.forwarding=1'
                    ],
                    'networks': {
                        'genieacs-net': {'ipv4_address': f'{docker_subnet}.254'},
                        'gacs-radius-net': None
                    }
                },
                'mongodb': {
                    'image': 'mongo:4.4',
                    'restart': 'always',
                    'volumes': ['mongo-data:/data/db'],
                    'networks': ['genieacs-net']
                },
                'genieacs-cwmp': {
                    'build': {
                        'context': str(SOURCE_DIR / version),
                        'dockerfile': f'../deploy/{version}/Dockerfile'
                    },
                    'restart': 'always',
                    'environment': {
                        'GENIEACS_MONGODB_CONNECTION_URL': 'mongodb://mongodb:27017/genieacs'
                    },
                    'ports': [f"{ports['cwmp']}:7547"],
                    'networks': {
                        'genieacs-net': {'ipv4_address': f'{docker_subnet}.100'}
                    },
                    'depends_on': ['mongodb'],
                    'cap_add': ['NET_ADMIN'],
                    'command': f'sh -c "{common_route_cmd}./dist/bin/genieacs-cwmp"'
                },
                'genieacs-nbi': {
                    'build': {
                        'context': str(SOURCE_DIR / version),
                        'dockerfile': f'../deploy/{version}/Dockerfile'
                    },
                    'restart': 'always',
                    'environment': {
                        'GENIEACS_MONGODB_CONNECTION_URL': 'mongodb://mongodb:27017/genieacs'
                    },
                    'ports': [f"{ports['nbi']}:7557"],
                    'networks': ['genieacs-net'],
                    'depends_on': ['mongodb'],
                    'cap_add': ['NET_ADMIN'],
                    'command': f'sh -c "{common_route_cmd}./dist/bin/genieacs-nbi"'
                },
                'genieacs-fs': {
                    'build': {
                        'context': str(SOURCE_DIR / version),
                        'dockerfile': f'../deploy/{version}/Dockerfile'
                    },
                    'restart': 'always',
                    'environment': {
                        'GENIEACS_MONGODB_CONNECTION_URL': 'mongodb://mongodb:27017/genieacs'
                    },
                    'ports': [f"{ports['fs']}:7567"],
                    'networks': ['genieacs-net'],
                    'depends_on': ['mongodb'],
                    'cap_add': ['NET_ADMIN'],
                    'command': f'sh -c "{common_route_cmd}./dist/bin/genieacs-fs"'
                },
                'genieacs-ui': {
                    'build': {
                        'context': str(SOURCE_DIR / version),
                        'dockerfile': f'../deploy/{version}/Dockerfile'
                    },
                    'restart': 'always',
                    'environment': {
                        'GENIEACS_MONGODB_CONNECTION_URL': 'mongodb://mongodb:27017/genieacs',
                        'GENIEACS_UI_JWT_SECRET': f'super_secret_{instance_name}'
                    },
                    'ports': [f"{ports['ui']}:3000"],
                    'networks': ['genieacs-net'],
                    'depends_on': ['mongodb'],
                    'cap_add': ['NET_ADMIN'],
                    'command': f'sh -c "{common_route_cmd}./dist/bin/genieacs-ui"'
                }
            },
            'volumes': {
                'mongo-data': None
            },
            'networks': {
                'genieacs-net': {
                    'ipam': {
                        'config': [{'subnet': f'{docker_subnet}.0/24'}]
                    }
                },
                'gacs-radius-net': {
                    'external': True
                }
            }
        }
        
        compose_file = target_dir / "docker-compose.yml"
        with open(compose_file, 'w') as f:
            yaml.dump(compose_data, f, default_flow_style=False)
        
        # Save instance metadata
        metadata = {
            'instance_name': instance_name,
            'version': version,
            'ports': ports,
            'docker_subnet': docker_subnet,
            'vpn_pool_base': vpn_pool_base,
            'onu_subnets': onu_subnets,
            'base_domain': base_domain,
            'ssl_enabled': ssl_enabled,
            'created_at': str(subprocess.check_output(['date', '+%Y-%m-%d %H:%M:%S']).decode().strip())
        }
        
        metadata_file = target_dir / "metadata.json"
        with open(metadata_file, 'w') as f:
            json.dump(metadata, f, indent=2)
        
        # Build and start containers
        try:
            subprocess.run(
                f"cd {target_dir} && {self.docker_compose_cmd} up -d --build",
                shell=True, check=True, capture_output=True
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Failed to start containers: {e.stderr.decode()}")
        
        # Wait for services
        import time
        time.sleep(15)
        
        # Configure OpenVPN routing
        self._configure_openvpn_routing(instance_name, onu_subnets, docker_subnet, vpn_pool_base)
        
        # Determine ACS URL
        acs_url = f"http://{docker_subnet}.100:7547"
        if base_domain:
            acs_url = f"http://cwmp-{instance_name}.{base_domain}"
        
        # Register NAS to RADIUS if available
        nas_secret = None
        try:
            result = subprocess.run(
                ['docker', 'ps', '-q', '-f', 'name=radius-mysql'],
                capture_output=True, text=True
            )
            if result.stdout.strip():
                nas_secret = self._register_nas_to_radius(
                    instance_name, vpn_pool_base, docker_subnet
                )
                if nas_secret:
                    with open(vpn_env_file, 'a') as f:
                        f.write(f"RADIUS_NAS_SECRET={nas_secret}\n")
        except Exception:
            pass  # RADIUS not available
        
        self._log_action("INSTALL", f"DONE - '{instance_name}' deployed")
        
        # Return connection info
        public_ip = self._get_public_ip()
        return {
            'status': 'success',
            'instance_name': instance_name,
            'version': version,
            'ports': ports,
            'docker_subnet': docker_subnet,
            'vpn_pool_base': vpn_pool_base,
            'public_ip': public_ip,
            'acs_url': acs_url,
            'nas_secret': nas_secret,
            'ovpn_profile_path': str(target_dir / "ovpn-data" / "client.ovpn"),
            'web_ui_url': f"http://acs-{instance_name}.{base_domain}" if base_domain else f"http://localhost:{ports['ui']}",
            'direct_access': {
                'ui': ports['ui'],
                'cwmp': ports['cwmp'],
                'nbi': ports['nbi'],
                'fs': ports['fs']
            }
        }
    
    def _configure_openvpn_routing(
        self,
        instance_name: str,
        onu_subnets: List[str],
        docker_subnet: str,
        vpn_pool_base: str
    ):
        """Configure OpenVPN routing and iptables"""
        ovpn_container = f"ovpn-{instance_name}"
        
        # Create CCD directory
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c', 'mkdir -p /etc/openvpn/ccd'],
            capture_output=True
        )
        
        # Clear client config
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c', ': > /etc/openvpn/ccd/client'],
            capture_output=True
        )
        
        # Add routes for each ONU subnet
        for subnet in onu_subnets:
            cidr = int(subnet.split('/')[1])
            subnet_ip = subnet.split('/')[0]
            
            # Calculate netmask
            full_octets = cidr // 8
            partial_octet = cidr % 8
            netmask_parts = []
            for i in range(4):
                if i < full_octets:
                    netmask_parts.append('255')
                elif i == full_octets:
                    netmask_parts.append(str(256 - 2**(8 - partial_octet)))
                else:
                    netmask_parts.append('0')
            netmask = '.'.join(netmask_parts)
            
            # Add iroute
            subprocess.run(
                ['docker', 'exec', ovpn_container, 'sh', '-c',
                 f"echo 'iroute {subnet_ip} {netmask}' >> /etc/openvpn/ccd/client"],
                capture_output=True
            )
            
            # Add route to server config
            subprocess.run(
                ['docker', 'exec', ovpn_container, 'sh', '-c',
                 f"grep -q 'route {subnet_ip}' /etc/openvpn/server/server.conf || "
                 f"echo 'route {subnet_ip} {netmask}' >> /etc/openvpn/server/server.conf"],
                capture_output=True
            )
        
        # Add client-config-dir directive
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c',
             "grep -q 'client-config-dir' /etc/openvpn/server/server.conf || "
             "echo 'client-config-dir /etc/openvpn/ccd' >> /etc/openvpn/server/server.conf"],
            capture_output=True
        )
        
        # Fix MikroTik compatibility - disable tls-crypt
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sed', '-i', '/tls-crypt tc.key/d',
             '/etc/openvpn/server/server.conf'],
            capture_output=True
        )
        
        # Switch to CBC cipher for MikroTik compatibility
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sed', '-i',
             's/cipher AES-128-GCM/cipher AES-256-CBC\\ndata-ciphers AES-256-CBC/g',
             '/etc/openvpn/server/server.conf'],
            capture_output=True
        )
        
        # Remove unsupported push options
        for option in ['redirect-gateway', 'block-ipv6', 'ifconfig-ipv6', 
                      'dhcp-option', 'block-outside-dns']:
            subprocess.run(
                ['docker', 'exec', ovpn_container, 'sed', '-i',
                 f'/push \"{option}/d', '/etc/openvpn/server/server.conf'],
                capture_output=True
            )
        
        # Set unique tun pool
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c',
             f"sed -i 's|^server[[:space:]].*|server {vpn_pool_base} 255.255.255.0|' "
             "/etc/openvpn/server/server.conf"],
            capture_output=True
        )
        
        # Clear IP pool
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c', ': > /etc/openvpn/server/ipp.txt'],
            capture_output=True
        )
        
        # Push Docker subnet route
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c',
             f"echo 'push \"route {docker_subnet}.0 255.255.255.0\"' >> "
             "/etc/openvpn/server/server.conf"],
            capture_output=True
        )
        
        # Create iptables script
        iptables_script = f"""#!/bin/sh
iptables -t nat -A POSTROUTING -s {vpn_pool_base}/24 -j MASQUERADE
iptables -I FORWARD -s {vpn_pool_base}/24 -j ACCEPT

RAD_IP=$(getent hosts radius 2>/dev/null | awk '{{print $1}}')
[ -z "$RAD_IP" ] && RAD_IP=$(nslookup radius 2>/dev/null | awk '/^Address: /{{print $2}}' | head -1)

if [ -n "$RAD_IP" ]; then
  iptables -t nat -A PREROUTING -d {docker_subnet}.1 -p udp --dport 1812 -j DNAT --to-destination $RAD_IP:1812
  iptables -t nat -A PREROUTING -d {docker_subnet}.1 -p udp --dport 1813 -j DNAT --to-destination $RAD_IP:1813
  iptables -t nat -A POSTROUTING -d $RAD_IP -p udp --dport 1812 -j MASQUERADE
  iptables -t nat -A POSTROUTING -d $RAD_IP -p udp --dport 1813 -j MASQUERADE
  iptables -I FORWARD -d $RAD_IP -j ACCEPT
fi
"""
        
        # Write and execute iptables script
        subprocess.run(
            ['docker', 'exec', '-i', ovpn_container, 'sh', '-c',
             'cat > /etc/openvpn/iptables.sh'],
            input=iptables_script.encode(),
            capture_output=True
        )
        
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'chmod', '+x', '/etc/openvpn/iptables.sh'],
            capture_output=True
        )
        
        # Add route-up directive
        subprocess.run(
            ['docker', 'exec', ovpn_container, 'sh', '-c',
             "grep -q 'route-up' /etc/openvpn/server/server.conf || "
             "echo -e '\\nscript-security 2\\nroute-up /etc/openvpn/iptables.sh' >> "
             "/etc/openvpn/server/server.conf"],
            capture_output=True
        )
        
        # Restart OpenVPN
        subprocess.run(
            ['docker', 'restart', ovpn_container],
            capture_output=True
        )
    
    def _register_nas_to_radius(
        self,
        instance_name: str,
        vpn_pool_base: str,
        docker_subnet: str
    ) -> Optional[str]:
        """Register NAS to central RADIUS database"""
        nas_secret = self._generate_random_password(16)
        nas_ip = f"{vpn_pool_base}/24"
        
        try:
            # Delete existing entry and insert new one
            subprocess.run(
                ['docker', 'exec', 'radius-mysql', 'mysql', '-u', 'radius',
                 '-pradiusdbpw', 'radius', '-e',
                 f"DELETE FROM nas WHERE nasname='{nas_ip}'; "
                 f"INSERT INTO nas (nasname, shortname, type, secret, description) "
                 f"VALUES ('{nas_ip}', '{instance_name}', 'other', '{nas_secret}', "
                 f"'Auto-generated for {instance_name}');"],
                capture_output=True, check=True
            )
            
            # Update Docker subnet entry
            subprocess.run(
                ['docker', 'exec', 'radius-mysql', 'mysql', '-u', 'radius',
                 '-pradiusdbpw', 'radius', '-e',
                 f"UPDATE nas SET secret='{nas_secret}' WHERE nasname='172.19.0.0/16';"],
                capture_output=True, check=True
            )
            
            # Get VPN container NAT IP
            try:
                result = subprocess.run(
                    ['docker', 'inspect', '-f',
                     '{{ (index .NetworkSettings.Networks "gacs-radius-net").IPAddress }}',
                     f'ovpn-{instance_name}'],
                    capture_output=True, text=True, check=True
                )
                vpn_nat_ip = result.stdout.strip()
                if vpn_nat_ip:
                    subprocess.run(
                        ['docker', 'exec', 'radius-mysql', 'mysql', '-u', 'radius',
                         '-pradiusdbpw', 'radius', '-e',
                         f"DELETE FROM nas WHERE nasname='{vpn_nat_ip}'; "
                         f"INSERT INTO nas (nasname, shortname, type, secret, description) "
                         f"VALUES ('{vpn_nat_ip}', '{instance_name}_NAT', 'other', '{nas_secret}', "
                         f"'NAT IP for {instance_name}');"],
                        capture_output=True, check=True
                    )
            except subprocess.CalledProcessError:
                pass
            
            # Restart FreeRADIUS
            subprocess.run(
                ['docker', 'restart', 'radius'],
                capture_output=True
            )
            
            self._log_action("RADIUS", f"NAS registered for '{instance_name}'")
            return nas_secret
            
        except subprocess.CalledProcessError as e:
            self._log_action("RADIUS", f"Failed to register NAS: {e}")
            return None
    
    def delete_customer_instance(self, instance_name: str) -> Dict:
        """
        Delete customer instance and all associated resources
        
        Args:
            instance_name: Instance name to delete
            
        Returns:
            Dict with deletion status
        """
        target_dir = INSTANCES_DIR / instance_name
        
        if not target_dir.exists():
            raise ValueError(f"Instance '{instance_name}' does not exist")
        
        self._log_action("UNINSTALL", f"START - '{instance_name}'")
        
        try:
            # Stop and remove containers
            subprocess.run(
                f"cd {target_dir} && {self.docker_compose_cmd} down -v --rmi all",
                shell=True, check=True, capture_output=True
            )
        except subprocess.CalledProcessError as e:
            pass  # Continue even if docker-compose fails
        
        # Remove Nginx config
        nginx_conf = NGINX_CONF_DIR / f"{instance_name}.conf"
        if nginx_conf.exists():
            nginx_conf.unlink()
            self._log_action("NGINX", f"Config removed for '{instance_name}'")
        
        # Remove from RADIUS
        try:
            result = subprocess.run(
                ['docker', 'ps', '-q', '-f', 'name=radius-mysql'],
                capture_output=True, text=True
            )
            if result.stdout.strip():
                subprocess.run(
                    ['docker', 'exec', 'radius-mysql', 'mysql', '-u', 'radius',
                     '-pradiusdbpw', 'radius', '-e',
                     f"DELETE FROM nas WHERE shortname='{instance_name}' OR "
                     f"shortname='{instance_name}_NAT';"],
                    capture_output=True
                )
                subprocess.run(
                    ['docker', 'restart', 'radius'],
                    capture_output=True
                )
        except Exception:
            pass
        
        # Remove instance directory
        import shutil
        shutil.rmtree(target_dir)
        
        self._log_action("UNINSTALL", f"DONE - '{instance_name}' fully removed")
        
        return {
            'status': 'success',
            'message': f"Instance '{instance_name}' deleted successfully"
        }
    
    def add_vpn_for_customer(
        self,
        instance_name: str,
        additional_routes: Optional[List[str]] = None
    ) -> Dict:
        """
        Add additional VPN configuration for existing customer
        
        Args:
            instance_name: Existing instance name
            additional_routes: Additional routes to add
            
        Returns:
            Dict with VPN configuration
        """
        target_dir = INSTANCES_DIR / instance_name
        
        if not target_dir.exists():
            raise ValueError(f"Instance '{instance_name}' does not exist")
        
        # Load metadata
        metadata_file = target_dir / "metadata.json"
        if not metadata_file.exists():
            raise RuntimeError(f"Metadata not found for '{instance_name}'")
        
        with open(metadata_file, 'r') as f:
            metadata = json.load(f)
        
        # Add routes if provided
        if additional_routes:
            ovpn_container = f"ovpn-{instance_name}"
            for route in additional_routes:
                # Add route to OpenVPN config
                subprocess.run(
                    ['docker', 'exec', ovpn_container, 'sh', '-c',
                     f"grep -q 'route {route}' /etc/openvpn/server/server.conf || "
                     f"echo 'route {route}' >> /etc/openvpn/server/server.conf"],
                    capture_output=True
                )
                
                # Add iroute
                cidr = int(route.split('/')[1]) if '/' in route else 24
                subnet_ip = route.split('/')[0]
                
                # Simplified netmask calculation
                netmask = "255.255.255.0" if cidr == 24 else "255.255.0.0" if cidr == 16 else "255.0.0.0"
                
                subprocess.run(
                    ['docker', 'exec', ovpn_container, 'sh', '-c',
                     f"echo 'iroute {subnet_ip} {netmask}' >> /etc/openvpn/ccd/client"],
                    capture_output=True
                )
            
            # Restart OpenVPN to apply changes
            subprocess.run(
                ['docker', 'restart', ovpn_container],
                capture_output=True
            )
            
            self._log_action("VPN", f"Added routes for '{instance_name}': {additional_routes}")
        
        return {
            'status': 'success',
            'instance_name': instance_name,
            'vpn_pool_base': metadata.get('vpn_pool_base'),
            'port': metadata.get('ports', {}).get('openvpn'),
            'routes_added': additional_routes or []
        }
    
    def add_route_for_vpn(
        self,
        instance_name: str,
        route: str
    ) -> Dict:
        """
        Add single route for customer VPN
        
        Args:
            instance_name: Instance name
            route: Route to add (e.g., "10.50.0.0/24")
            
        Returns:
            Dict with route addition status
        """
        return self.add_vpn_for_customer(instance_name, [route])
    
    def list_instances(self) -> List[Dict]:
        """List all instances with their status"""
        instances = []
        
        if not INSTANCES_DIR.exists():
            return instances
        
        for instance_dir in INSTANCES_DIR.iterdir():
            if not instance_dir.is_dir():
                continue
            
            instance_name = instance_dir.name
            metadata_file = instance_dir / "metadata.json"
            
            # Check if running
            running_containers = 0
            try:
                result = subprocess.run(
                    [self.docker_compose_cmd.split()[0]] + 
                    self.docker_compose_cmd.split()[1:] + 
                    ['ps', '--status', 'running', '-q'],
                    cwd=instance_dir,
                    capture_output=True, text=True
                )
                running_containers = len([l for l in result.stdout.strip().split('\n') if l])
            except Exception:
                pass
            
            instance_info = {
                'name': instance_name,
                'status': 'running' if running_containers > 0 else 'stopped',
                'running_containers': running_containers,
                'path': str(instance_dir)
            }
            
            if metadata_file.exists():
                with open(metadata_file, 'r') as f:
                    instance_info.update(json.load(f))
            
            instances.append(instance_info)
        
        return instances
    
    def get_instance_detail(self, instance_name: str) -> Dict:
        """Get detailed information about an instance"""
        target_dir = INSTANCES_DIR / instance_name
        
        if not target_dir.exists():
            raise ValueError(f"Instance '{instance_name}' does not exist")
        
        metadata_file = target_dir / "metadata.json"
        if not metadata_file.exists():
            raise RuntimeError(f"Metadata not found for '{instance_name}'")
        
        with open(metadata_file, 'r') as f:
            detail = json.load(f)
        
        # Add runtime status
        try:
            result = subprocess.run(
                [self.docker_compose_cmd.split()[0]] + 
                self.docker_compose_cmd.split()[1:] + 
                ['ps', '--format', 'json'],
                cwd=target_dir,
                capture_output=True, text=True
            )
            detail['containers'] = json.loads(result.stdout) if result.stdout.strip() else []
        except Exception:
            detail['containers'] = []
        
        return detail


# Singleton instance
manager = GACSManager()
