# Analisa Komprehensif Arsitektur dan Perbedaan GenieACS (Stable vs Latest)

Dokumen ini berisi analisis mendalam mengenai proyek **GenieACS**, sebuah *Auto Configuration Server* (ACS) berbasis protokol TR-069 (CWMP) berkinerja tinggi. Analisis ini membandingkan *source code* dari dua versi yang ada pada direktori proyek:
1. **Stable**: Mengacu pada versi rilis stabil `v1.2.16`.
2. **Latest**: Mengacu pada cabang pengembangan untuk versi `v1.3.0-dev`.

---

## 1. Tinjauan Arsitektur Utama (High-Level Architecture)

Secara fundamental, arsitektur dasar GenieACS dipertahankan pada kedua versi. Keduanya terdiri dari 4 layanan uatama (services) yang saling terpisah namun berbagi koneksi basis data (MongoDB):

- **genieacs-cwmp (Port 7547)**: Server inti penyedia protokol TR-069. Perangkat CPE terkoneksi ke layanan ini untuk melaporkan kondisi (Inform) dan menerima perintah konfigurasi.
- **genieacs-nbi (Port 7557)**: *Northbound Interface*. API REST eksternal untuk otomasi sistem, integrasi OSS/BSS, maupun manajemen tugas tingkat lanjut.
- **genieacs-fs (Port 7567)**: *File Server* ringan yang difungsikan untuk menyediakan pembaruan *firmware* maupun transfer fail konfigurasi (via GridFS).
- **genieacs-ui (Port 3000)**: Aplikasi *backend* berbasis Koa yang melayani kerangka antarmuka pengguna SPA (Single Page Application).

Fitur unggulan arsitektur GenieACS yang konsisten ada:
- **Declarative Session Engine**: Alih-alih melakukan perintah iteratif ke *router* secara langsung, administrator "mendeklarasikan" *state* seperti apa yang diinginkan. Mesin sesi (`lib/session.ts`) secara otomatis membuat perencanaan (plan) perubahan yang optimal.
- **Expression Engine**: Digunakan layaknya bahasa SQL primitif yang menjangkau seluruh kode, yang mencakup otorisasi presisi tinggi, validasi, kueri kompleks, hingga evaluasi prasyarat (preconditions). Logika ekspresi ini diproses hingga diubah menjadi kueri MongoDB performa tinggi.
- **Sandbox Execution**: Mengeksekusi *virtual parameters* maupun *provision scripts* (Javascript) di zona aman (*V8 Context/Interpreter*) secara aman yang dikendalikan oleh waktu tenggat eksekusi secara deterministik (dilakukan tanpa celah kerentanan re-eksekusi).

---

## 2. Perubahan Fundamental Antara `stable` (v1.2) dan `latest` (v1.3.0-dev)

Dalam pengembangan ke seri `1.3.0-dev`, tim pengembang melakukan beberapa perombakan masif untuk meningkatkan skalabilitas dan modernisasi. Berikut ini perbandingan teknis antar versi:

### A. Evaluasi Ulang Modul *Expression Parser* (`lib/common/expression/parser.ts`)
- **Stable (v1.2.x)**: Memanfaatkan pustaka pihak ketiga `parsimmon` (sebuah pustaka *Parser Combinator*) untuk mem-parsing sintaks SQL milik GenieACS ke dalam *Abstract Syntax Tree* (AST). Parser ini cukup kuat tapi *overhead* memorinya cukup besar untuk volume skala masif.
- **Latest (v1.3.x)**: Menghilangkan total dependensi `parsimmon` dan menggantinya dengan **Hand-rolled Recursive Descent Parser** secara kustom menggunakan kelas objek statis `Cursor`. Langkah drastis ini bertujuan untuk memaksimalkan performa *parsing*, menurunkan *footprint* memori saat terjadi ribuan eksekusi per-detik, serta memberikan fleksibilitas ekstra untuk sintaks-sintaks perulangan baru di depannya.

### B. Modernisasi Besar pada Antarmuka Pengguna (Frontend/UI)
Bagian dari direktori `ui/` dirancang ulang dari bawah-ke-atas:
- **Pengenalan JSX/TSX dengan Mithril.js**: 
  - *Stable:* Komponen antarmuka menggunakan pemanggilan `m()` berantai khas Mithril di dalam berkas-berkas murni TypeScript (`.ts`).
  - *Latest:* Transisi sepenuhnya menuju format sintaksis React (`.jsx` / `.tsx`). Berkas-berkas seperti `ui/components/login-page.tsx`, `ui/components/layout.tsx` adalah pendekatan modern berkat kapabilitas parser esbuild yang mendukung *"jsxFactory": "m"*. Hal ini mempermudah keterbacaan struktur HTML antarmuka.
- **Sistem *Styling* (Tailwind CSS)**: 
  - *Stable:* Menggunakan fail vanilla CSS ukuran besar, serta komponen utilitas manual (`ui/css/app.css` & `normalize.css`).
  - *Latest:* Mengadopsi kerangka kerja rilis termutakhir **Tailwind CSS v4**. Modul utilitas *CSS-in-JS* diaktifkan dan `esbuild` menggunakan `npx @tailwindcss/cli` untuk hanya menyertakan properti CSS yang dipakai, memotong durasi load laman.
- **Sistem Penyuntingan Skrip (CodeMirror)**:
  - *Stable*: Memasang pustaka lawas `@types/codemirror` (v5).
  - *Latest*: Melompat ke **CodeMirror v6** (sistem ekosistem modular independen berorientasi ekstensi untuk web rilis teranyar).

### C. Pemisahan Modul Dasar-Data (*Seed Data*)
Berkas inisiasi `lib/init.ts` bertugas membangun akun admin, pandangan UI default (views), preseti, dsb untuk pangkalan-data graf saat baru pertama kali digunakan.
- **Stable**: Berkas `init.ts` sangat membengkak (~16KB) karena mendefinisikan *hard-code* teks logika konfigurasi peranti dan XML secara raksasa secara *inline* di dalam kodenya.
- **Latest**: Ukuran `init.ts` mengecil setengahnya. Seluruh *template* ditarik dan dipisahkan menjadi dokumen logis terenkapsulasi pada direktori root **`seed/`**. Di tingkat *compiler*, rilis v1.3 memanggil berkas bawaan ini menggunakan ES Module import assertions (`import ... with { type: "text" }`).

### D. Peraturan *Build System* (`build/build.ts`)
Baik `stable` maupun `latest` tidak menggunakan bundler umum seperti Webpack. Proyek di-*build* dengan kompilator ultra-cepat **ESBuild** memalui Node script:
- Pustaka internal `latest` menyesuaikan penambahan fungsi *plugin* seperti ekstrak seed statis (`seedPlugin`) hingga pemanggilan plugin pembentukan kelas untuk kelas-kelas Taildwind (`tailwindPlugin`).
- *Backend logic build* menghasilkan 5 *binaries* utama ke folder `dist/bin/`.

---

## 3. Evaluasi Dependensi (Berdasarkan `package.json`)

| Pustaka Dependensi | Stable (v1.2.16) | Latest (v1.3.0-dev) | Analisis Penggunaan / Implikasi |
|---|---|---|---|
| Engine Minimum | Node >= `12.13.0` | Node >= `12.13.0` | Masih mempertahankan kompatibilitas lingkungan yang stabil ke belakang. Namun TypeScript di update mengarah pada Node 18 target transpile. |
| DB Driver | `mongodb` ^4.16.0 | `mongodb` ^4.16.0 | Versi sama. Tidak ada migrasi sintaks operasi MongoDB skala besar dari v1.2 ke v1.3. |
| REST Framework | `koa` & variasinya | `koa` & variasinya | Masih sejalan menggunakan abstraksi Koa versi 2. Kestabilan tinggi untuk modul NBI dan UI api internal. |
| Parser Text | `parsimmon` | *(Dihapus/Removed)* | Didepak guna perbaikan performa ekspresi yang diproses pada skala perangkat IOT yang jutaan. |
| Linter | `eslint` ^8 | `eslint` ^10 | Transformasi esktra ketat pemeliharaan sintaks, dan memaksimalkan standardisasi koding mutakhir. |

---

## 4. Kesimpulan Rencana Peluncuran / Implikasi Bisnis

Transisi dari ranting `stable` (v1.2) ke `latest` (v1.3-dev) di dalam GenieACS sebagian besar mencakup **refaktor teknis di bawah lapisan (under-the-hood)** yang diarahkan langsung pada:
1. Peningkatan pemeliharaan jangka panjang UI secara masif oleh pengembang depan melalui **JSX dan Tailwind v4**. 
2. Membebaskan diri dari beban komputasi besar (menghemat jejak CPU/RAM dari string *parsing*) berkat pengonversi sintaks *custom parser* yang mempreteli latensi eksekusi *Expressions Engine*.

**Rekomendasi *Deployment*:**
- Lingkungan produksi mutlak tetap harus mengarahkan haluannya kepada `stable` (v1.2) memandang tidak adanya regresi kestabilan.
- Meskipun `latest` secara struktural lebih modular (di bidang kode depannya), ia masih berada di tahap rilis versi pengembang stabil-sementara, beberapa modul seperti *parser hand-rolled* masih rawan terhadap *bug-edge case logic* operasional. Sangat menjanjikan untuk dilakukan pengujian UAT (User Acceptance Testing) jika dirasa perlu di internal Anda sebelum peluncuran resmi v1.3 mendunia.
