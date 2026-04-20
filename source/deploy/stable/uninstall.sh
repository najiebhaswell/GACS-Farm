#!/usr/bin/env bash
set -e

echo "⚠️  Menghapus instalasi GenieACS (Stable)..."
echo "Memberhentikan container penyangga, menghapus volume DB, dan menghilangkan images..."

docker compose down -v --rmi all

echo ""
echo "✅ Uninstall komplit! Seluruh file container, database (volume), dan image telah dihapus tak berbekas."
