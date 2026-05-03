# 🚜 GACS-Farm — GenieACS Multi-Instance Orchestrator

CLI manager untuk deploy, monitor, dan manage **multi-instance GenieACS (TR-069 ACS)** pada satu VPS, dengan **OpenVPN per instance (container)** agar MikroTik di lokasi bisa menjangkau subnet ONU dan ACS (TR-069).

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04-orange.svg)
![GenieACS](https://img.shields.io/badge/GenieACS-v1.2%20%7C%20v1.3-green.svg)

---

## ✨ Fitur

| Fitur | Deskripsi |
|---|---|
| **Multi-Instance** | Deploy banyak GenieACS instance di satu server, masing-masing terisolasi |
| **Auto Port Allocation** | Port CWMP/NBI/FS/UI dialokasikan otomatis tanpa bentrok |
| **Nginx Reverse Proxy** | Subdomain otomatis per instance (`acs-<nama>.domain.id`) |
| **Wildcard SSL/HTTPS** | SSL via Let's Encrypt + Cloudflare DNS-01 challenge |
| **OpenVPN per instance** | Satu container OpenVPN per instance; profil `.ovpn` untuk import ke MikroTik |
| **ONU Route Management** | Route subnet ONU di jembatan Docker + OpenVPN (`iroute` / `route`) agar CWMP menjangkau CPE |
| **Parameter Restore** | Restore provisions, virtual params, presets, UI config dari preset |
| **Version Support** | GenieACS Stable (v1.2) dan Latest (v1.3-dev) |
| **Pause/Unpause** | Freeze instance tanpa menghentikan container |
| **Activity Log** | Riwayat semua aksi dengan filter dan search |

---

## 🏗️ Arsitektur

Setiap **instance** punya stack Docker sendiri: MongoDB, empat proses GenieACS, dan **satu container OpenVPN** (UDP, port host unik). MikroTik mengimpor **`instances/<nama>/ovpn-data/...` (.ovpn)**; tunnel membawa route ke subnet LAN/ONU yang Anda masukkan saat install. **Nginx** di host mem-proxy subdomain ke port UI/CWMP/NBI/FS di loopback.

```
┌──────────────────────────────────────────────────────────────┐
│                         VPS (Cloud)                           │
│  ┌────────────────┐  ┌────────────────┐                     │
│  │   Instance A    │  │   Instance B    │   ...               │
│  │ MongoDB         │  │ MongoDB         │                     │
│  │ CWMP/NBI/FS/UI  │  │ CWMP/NBI/FS/UI  │                     │
│  │ + OpenVPN :PORT │  │ + OpenVPN :PORT │  (per-instance UDP)│
│  └────────┬────────┘  └────────┬────────┘                     │
│           │                     │                              │
│  ┌────────┴─────────────────────┴────────────────────────┐  │
│  │              Nginx (reverse proxy + SSL)               │  │
│  └──────────────────────────┬─────────────────────────────┘  │
└─────────────────────────────┼────────────────────────────────┘
                              │ Internet
                    ┌─────────┴─────────┐
                    │     MikroTik       │  ← OpenVPN client (.ovpn)
                    └─────────┬─────────┘
                              │
                         ONU / LAN subnet
```

---

## 📦 Instalasi

### Prasyarat
- **OS**: Ubuntu 22.04+ (atau Debian-based)
- **Docker & Docker Compose**: [Install Docker](https://docs.docker.com/engine/install/ubuntu/)
- **Git & Curl**: `apt install git curl`
- **Domain** dengan Wildcard DNS Record (`*.domain.id → IP VPS`)
- **Cloudflare API Token** (untuk SSL)

> Script otomatis mengecek root permission dan semua dependency saat dijalankan.

### Quick Start

```bash
# 1. Clone repository (path bebas)
git clone https://github.com/safrinnetwork/GACS-Farm.git /home/docker/genieacs
cd /home/docker/genieacs/manager

# 2. Jalankan manager (harus root)
chmod +x mostech-gacs.sh
sudo ./mostech-gacs.sh
```

> Path clone bebas, script auto-detect lokasi. Contoh: `/opt/genieacs`, `/root/gacs`, dll.

### 🚀 Setup Pertama Kali (Fresh VPS)

Ikuti urutan ini di dalam manager:

```
┌─ 3. Services & Settings
│   ├─ 4. Setup GenieACS Source  ← Clone source stable/latest
│   ├─ 2. Install Services      ← Install Nginx + Certbot
│   └─ 1. Setup Domain & SSL    ← Konfigurasi domain + SSL
│
└─ 1. Manage Instance
    └─ 1. Install New Instance   ← Deploy GenieACS pertama
```

**Langkah detail:**
1. Pilih `3` → Services & Settings → `4` Setup GenieACS Source → Clone Stable/Latest
2. Pilih `3` → Services & Settings → `2` Install Services → Install All
3. Pilih `3` → Services & Settings → `1` Setup Domain & SSL
4. Pilih `1` → Manage Instance → `1` Install New Instance

---

## 🎮 Penggunaan

```bash
cd /home/docker/genieacs/manager
sudo ./mostech-gacs.sh
```

### Main Menu
```
╔══════════════════════════════════════════╗
║       MOSTECH GACS MANAGER v1.2          ║
║    GenieACS Multi-Instance Orchestrator  ║
╚══════════════════════════════════════════╝

  Instances: 1  │  Domain: domain.id  │  SSL: Active  │  Docker: Active
──────────────────────────────────────────
  1. Manage Instance
  2. View Activity Log
  3. Services & Settings
  0. Exit
```

### [1] Manage Instance
```
  1. Install New Instance
  2. Monitor Resources
  3. Pause / Unpause
  4. Uninstall Instance
  5. Update ONU Subnet
  0. Back
```

### [3] Services & Settings
```
  Nginx: Active  │  Certbot: Ready
  Domain: domain.id  │  SSL: Active
  Source Stable: Ready  │  Source Latest: Ready
──────────────────────────────────────────
  1. Setup Domain & SSL
  2. Install Services
  3. Uninstall Services
  4. Setup GenieACS Source
  0. Back
```

### Install Instance — Auto Flow
Script akan otomatis:
- Alokasi port unik (CWMP/NBI/FS/UI)
- Build & start Docker containers
- Generate Nginx proxy config
- Deploy container **OpenVPN** (port UDP unik) + sesuaikan route ke subnet ONU
- Prompt subnet ONU → route di stack Docker (CWMP ↔ jaringan OpenVPN)
- Prompt restore parameter preset
- Tampilkan info koneksi lengkap + panduan MikroTik

---

## 🔌 Konektivitas ONU via OpenVPN (container)

1. Setelah install instance, ambil file **`instances/<nama-instance>/ovpn-data/`** (misalnya `clients/client.ovpn` — path persis ditampilkan di akhir wizard install).
2. **Import** profil ke MikroTik ( atau client OpenVPN), hubungkan ke **IP publik VPS** dan **port UDP** yang dicetak di summary install.
3. Pastikan **subnet ONU** yang Anda masukkan saat install sesuai LAN di belakang MikroTik; skrip mengatur route/`iroute` agar trafik ACS–ONU konsisten.
4. **ACS URL** untuk CPE (OLT/profile TR-069): gunakan URL CWMP yang ditampilkan, misalnya dengan domain:
   `http://cwmp-<nama>.<domain-anda>`  
   atau IP internal sesuai topologi Anda (lihat output **Direct access** / summary install).

### Tun pool per pelanggan (RADIUS / firewall)

Setiap instance mendapat **subnet OpenVPN tun sendiri** dalam bentuk **`172.27.x.0/24`** (unik per instance pada VPS). Disimpan di **`instances/<nama>/.vpn_tun_pool`**.

- **IP VPN MikroTik** (bukan IP ONU) berada di rentang itu — umumnya `.2` untuk klien pertama (`topology subnet`).
- Di **RADIUS** atau firewall server pusat, Anda bisa **allow** traffic dari **`172.27.x.0/24`** untuk pelanggan/instance tersebut, tanpa mencampur dengan subnet ONU di lokasi.

Instance yang dipasang **sebelum** fitur ini memakai default image **`10.8.0.0/24`** di dalam container; untuk menyamakan perilaku, sesuaikan manual `server` di `ovpn-data/server/server.conf`, kosongkan `ipp.txt`, lalu restart container OpenVPN.

---

## 📁 Struktur Direktori

```
/home/docker/genieacs/
├── README.md
├── .gitignore
├── manager/
│   ├── mostech-gacs.sh          # Script CLI utama
│   ├── config.conf              # Config per-VPS (runtime)
│   ├── log.txt                  # Activity log (runtime)
│   └── nginx/                   # Nginx configs (runtime)
├── instances/                   # Instance data (runtime)
│   └── <instance>/
│       ├── docker-compose.yml
│       ├── vpn.env              # Env OpenVPN (DNS publik acs-*, dll.)
│       ├── ovpn-data/            # Data & profil OpenVPN server/client
│       ├── .vpn_tun_pool        # Rentang tun per instance (172.27.x.0/24), untuk RADIUS
│       └── .onu_subnet          # Subnet ONU (info)
└── source/
    ├── deploy/
    │   ├── stable/Dockerfile
    │   └── latest/Dockerfile
    ├── GACS-Ubuntu-22.04/
    │   └── parameter/           # Preset BSON files
    ├── stable/                  # GenieACS v1.2 (clone via menu)
    └── latest/                  # GenieACS v1.3 (clone via menu)
```

---

## 🔐 Subdomain Pattern

| Service | Subdomain | Protocol |
|---|---|---|
| Web UI | `acs-<nama>.domain.id` | HTTPS |
| CWMP | `cwmp-<nama>.domain.id` | HTTP |
| NBI | `nbi-<nama>.domain.id` | HTTP |
| FS | `fs-<nama>.domain.id` | HTTP |

---

## 📝 Catatan

- **Root Required**: Script harus dijalankan sebagai root (`sudo`).
- **Dependency Auto-Check**: Script otomatis cek Docker, Git, Curl saat startup.
- **Parameter Restore**: Otomatis mendeteksi versi. Stable restore 4 collection (termasuk UI config), Latest hanya 3 (skip config karena UI v1.3 berbeda).
- **Route & VPN**: Routing ONU diarahkan lewat **jaringan bridge instance + OpenVPN** per instance.
- **Periodic Inform**: Set interval 60 detik di OLT profile untuk near-realtime management.

---

## 📜 License

MIT License — by [Mostech/Safrin Network](https://github.com/safrinnetwork)
