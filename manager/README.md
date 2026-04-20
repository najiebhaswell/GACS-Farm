# Mostech GACS Manager

CLI interaktif untuk mendeploy, memonitor, dan mengelola **GenieACS (TR-069)** multi-instans dalam satu server, dilengkapi reverse proxy Nginx, SSL/HTTPS otomatis, dan L2TP VPN untuk konektivitas ONU lokal.

---

## 🚀 Cara Menjalankan

```bash
cd /home/docker/genieacs/manager
sudo ./mostech-gacs.sh
```

> **Prasyarat:** Root permission, Docker, Git, Curl. Script otomatis cek saat startup.

---

## 🛠️ Menu

### [1] Manage Instance
Submenu untuk mengelola semua instance GenieACS:
- **Install New Instance** — Deploy instance baru (Stable/Latest) dengan port acak, L2TP user otomatis, dan parameter restore.
- **Monitor Resources** — Pantau CPU/RAM/Network per instance secara real-time via `docker stats`.
- **Pause / Unpause** — Freeze atau unfreeze instance tanpa menghentikan container.
- **Uninstall Instance** — Hapus total container, image, volume, konfigurasi Nginx, L2TP user, dan route.

### [2] View Activity Log
Baca riwayat semua aksi dari `log.txt`. Mendukung filter dan pencarian kata kunci.

### [3] Services & Settings
Submenu untuk konfigurasi infrastruktur:

- **Setup Domain & SSL** — Konfigurasi terpadu 3-in-1:
  - **Domain:** Atur domain utama (contoh: `gtocloud.id`)
  - **Cloudflare API Token:** Validasi otomatis (cek token aktif + akses zone)
  - **SSL/HTTPS:** Wildcard certificate `*.domain.id` via Let's Encrypt + Cloudflare DNS-01

- **Install Services** — L2TP Server, Nginx Proxy, Certbot (atau Install All)

- **Uninstall Services** — Hapus service yang terinstall

- **Setup GenieACS Source** — Clone GenieACS source code (Stable v1.2 / Latest v1.3-dev) dari GitHub repository resmi. **Wajib dilakukan sebelum install instance pertama.**

---

## 🔐 Cara Membuat Cloudflare API Token

1. Login ke [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Klik **My Profile** → **API Tokens** → **Create Token**
3. Gunakan template **Edit zone DNS** atau buat custom:
   - Permission: `Zone → DNS → Edit`
   - Zone Resources: `Include → Specific zone → domain Anda`
4. Salin token yang dihasilkan

---

## 📁 Struktur File

```
/home/docker/genieacs/
├── manager/
│   ├── mostech-gacs.sh        # Script CLI utama
│   ├── config.conf             # Domain, API Token, Email, SSL status
│   ├── log.txt                 # Riwayat semua aksi
│   └── nginx/
│       ├── docker-compose.yml
│       ├── nginx.conf
│       ├── conf.d/             # Config per-instans (otomatis)
│       └── ssl/                # Sertifikat Let's Encrypt
├── instances/                  # Folder per-instans (otomatis)
└── source/
    ├── deploy/                 # Dockerfiles
    ├── GACS-Ubuntu-22.04/
    │   └── parameter/          # Preset BSON files
    ├── stable/                 # GenieACS v1.2 (clone via menu)
    └── latest/                 # GenieACS v1.3 (clone via menu)
```

---

## 📌 Subdomain Pattern

| Service | Subdomain | Protokol |
|---|---|---|
| UI | `acs-<nama>.domain.id` | HTTPS (jika SSL aktif) |
| CWMP | `cwmp-<nama>.domain.id` | HTTP |
| NBI | `nbi-<nama>.domain.id` | HTTP |
| FS | `fs-<nama>.domain.id` | HTTP |

**Prasyarat DNS:** Wildcard A Record `*.domain.id → IP Server`
