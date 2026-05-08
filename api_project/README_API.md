# API VPN Management System - GACS Integration

## 📋 Ringkasan Fitur

API ini telah diintegrasikan dengan **GACS Manager** (Python) untuk otomatisasi penuh deployment instance GenieACS dan OpenVPN menggunakan Docker.

## 🔧 Perubahan Utama

### 1. **GACS Manager Module** (`gacs_manager.py`)
Module Python yang menggantikan bash script `mostech-gacs.sh` dengan fungsi-fungsi native Python:

#### Fungsi Utama:
- `create_customer_instance()` - Deploy instance GenieACS + OpenVPN baru
- `delete_customer_instance()` - Hapus instance beserta semua resources Docker
- `add_vpn_for_customer()` - Tambahkan routes VPN untuk customer
- `add_route_for_vpn()` - Tambahkan single route ke VPN
- `list_instances()` - List semua instances dengan status
- `get_instance_detail()` - Detail lengkap instance

### 2. **API Endpoints yang Diupdate**

#### 👥 CUSTOMERS
| Method | Endpoint | Fungsi |
|--------|----------|--------|
| `POST` | `/api/customers` | **Create instance** dengan Docker (GenieACS + OpenVPN) |
| `GET` | `/api/customers` | List semua customers |
| `GET` | `/api/customers/<id>` | Detail customer |
| `DELETE` | `/api/customers/<id>` | **Delete instance** dan semua containers |

**Request Body POST /api/customers:**
```json
{
  "name": "customer-abc",
  "version": "stable",
  "onu_subnet": "10.50.0.0/16,10.51.0.0/16",
  "base_domain": "example.com",
  "ssl_enabled": false
}
```

**Response:**
```json
{
  "success": true,
  "message": "Customer instance created successfully with Docker containers",
  "data": {
    "status": "success",
    "instance_name": "customer-abc",
    "version": "stable",
    "ports": {
      "cwmp": 7845,
      "nbi": 3421,
      "fs": 5632,
      "ui": 8901,
      "openvpn": 4567
    },
    "docker_subnet": "10.123.45",
    "vpn_pool_base": "10.150.23",
    "public_ip": "203.0.113.10",
    "acs_url": "http://cwmp-customer-abc.example.com",
    "nas_secret": "aB3dE5fG7hI9jK1l",
    "ovpn_profile_path": "/workspace/instances/customer-abc/ovpn-data/client.ovpn",
    "web_ui_url": "http://acs-customer-abc.example.com"
  }
}
```

#### 🔒 VPNS
| Method | Endpoint | Fungsi |
|--------|----------|--------|
| `POST` | `/api/customers/<id>/vpns` | **Add routes** ke OpenVPN instance |
| `GET` | `/api/vpns` | List semua VPNs |
| `GET` | `/api/vpns/<id>` | Detail VPN |
| `DELETE` | `/api/vpns/<id>` | Delete VPN |

**Request Body POST /api/customers/<id>/vpns:**
```json
{
  "name": "VPN-Site-A",
  "type": "openvpn",
  "network": "10.50.0.0/16",
  "routes": ["10.50.0.0/16", "10.51.0.0/24"]
}
```

#### 🛣️ ROUTES
| Method | Endpoint | Fungsi |
|--------|----------|--------|
| `POST` | `/api/vpns/<id>/routes` | **Add route** ke VPN instance |
| `GET` | `/api/routes` | List semua routes |
| `GET` | `/api/routes/<id>` | Detail route |
| `DELETE` | `/api/routes/<id>` | Delete route |

**Request Body POST /api/vpns/<id>/routes:**
```json
{
  "destination": "192.168.100.0/24",
  "gateway": "10.0.1.1",
  "description": "Route to branch office"
}
```

## 🚀 Cara Menggunakan

### 1. Start API Server
```bash
cd /workspace/api_project
API_PORT=8081 python3 app.py
```

### 2. Create Customer Instance
```bash
curl -X POST http://localhost:8081/api/customers \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pt-telkom",
    "version": "stable",
    "onu_subnet": "10.50.0.0/16",
    "base_domain": "gacs.telkom.co.id"
  }'
```

### 3. Add VPN Routes
```bash
curl -X POST http://localhost:8081/api/customers/1/vpns \
  -H "Content-Type: application/json" \
  -d '{
    "name": "VPN-Jakarta",
    "type": "openvpn",
    "routes": ["10.50.0.0/16", "192.168.1.0/24"]
  }'
```

### 4. Add Additional Route
```bash
curl -X POST http://localhost:8081/api/vpns/1/routes \
  -H "Content-Type: application/json" \
  -d '{
    "destination": "172.16.0.0/12",
    "gateway": "10.0.1.254",
    "description": "Internal network"
  }'
```

### 5. Delete Instance
```bash
curl -X DELETE http://localhost:8081/api/customers/1
```

## 📁 Struktur Folder

```
/workspace/
├── api_project/
│   ├── app.py              # Flask API server
│   ├── gacs_manager.py     # Python orchestration module
│   └── requirements.txt
├── manager/
│   └── mostech-gacs.sh     # Bash script (referensi)
├── source/
│   ├── stable/             # GenieACS v1.2 source
│   └── latest/             # GenieACS v1.3.0-dev source
└── instances/              # Auto-created per customer
    └── <instance-name>/
        ├── docker-compose.yml
        ├── vpn.env
        ├── metadata.json
        └── ovpn-data/
```

## ✅ Apa yang Otomatis Dilakukan

Saat create customer via API:

1. ✅ **Allocate Ports** - CWMP, NBI, FS, UI, OpenVPN
2. ✅ **Create Docker Network** - Isolated subnet per instance
3. ✅ **Generate docker-compose.yml** - MongoDB + GenieACS (cwmp/nbi/fs/ui) + OpenVPN
4. ✅ **Build & Start Containers** - Semua services dalam Docker
5. ✅ **Configure OpenVPN** - Routes, iroute, iptables, NAT
6. ✅ **MikroTik Compatibility** - Cipher CBC, disable tls-crypt
7. ✅ **Register to RADIUS** - NAS entry dengan secret otomatis
8. ✅ **Generate Metadata** - Simpan info instance ke JSON

Saat delete customer:
1. ✅ **Stop & Remove Containers** - docker-compose down
2. ✅ **Remove Volumes** - Database MongoDB
3. ✅ **Remove Nginx Config** - Proxy configuration
4. ✅ **Unregister from RADIUS** - Delete NAS entry
5. ✅ **Delete Instance Directory** - Cleanup semua files

## 🌐 Web UI

Akses **http://localhost:8081** untuk antarmuka web grafis.

## 📝 Notes

- Pastikan Docker dan Docker Compose terinstall
- Pastikan source GenieACS tersedia di `/workspace/source/stable` atau `/workspace/source/latest`
- Port otomatis dipilih yang available (random 1000-9999)
- Setiap instance mendapat isolated Docker network
- OpenVPN profile (.ovpn) tersimpan di `instances/<name>/ovpn-data/client.ovpn`
