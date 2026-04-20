#!/usr/bin/env bash
set -e

echo "🚀 Memulai proses build dan deploy GenieACS (Stable)..."
docker compose up -d --build

echo ""
echo "✅ Deploy berhasil! Komponen GenieACS saat ini sedang berjalan."
echo "▶ UI    : http://localhost:3000"
echo "▶ CWMP  : http://localhost:7547"
echo ""
echo "Gunakan 'docker compose logs -f' untuk meninjau status dan log proses."
