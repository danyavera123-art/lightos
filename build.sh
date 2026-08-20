#!/bin/bash
# LightOS build script (Debian 12 + XFCE + Calamares)
# Требуется запуск от root: sudo ./build.sh
set -e
set -o pipefail

cd "$(dirname "$0")"

# Сделать скрипты исполняемыми (крючки live-build и скрипты системы)
chmod -R +x config/hooks config/includes.chroot/usr/bin 2>/dev/null || true
chmod -R +x config/includes.chroot/etc/skel 2>/dev/null || true
chmod +x config/includes.chroot/etc/skel/.config/autostart/lightos-firstboot.desktop 2>/dev/null || true

echo "==> Очистка предыдущей сборки (если есть)"
lb clean 2>/dev/null || true

echo "==> Конфигурация live-build"
lb config \
  --mode debian \
  --distribution bookworm \
  --architectures amd64 \
  --system live \
  --linux-flavours amd64 \
  --linux-packages "linux-image" \
  --archive-areas "main contrib non-free-firmware" \
  --parent-mirror-bootstrap "http://deb.debian.org/debian/" \
  --parent-mirror-chroot "http://deb.debian.org/debian/" \
  --parent-mirror-chroot-security "http://security.debian.org/debian-security/" \
  --parent-mirror-chroot-volatile "http://deb.debian.org/debian/" \
  --parent-mirror-binary "http://deb.debian.org/debian/" \
  --parent-mirror-binary-security "http://security.debian.org/debian-security/" \
  --parent-mirror-binary-volatile "http://deb.debian.org/debian/" \
  --mirror-bootstrap "http://deb.debian.org/debian/" \
  --mirror-chroot "http://deb.debian.org/debian/" \
  --mirror-chroot-security "http://security.debian.org/debian-security/" \
  --mirror-chroot-volatile "http://deb.debian.org/debian/" \
  --mirror-binary "http://deb.debian.org/debian/" \
  --mirror-binary-security "http://security.debian.org/debian-security/" \
  --mirror-binary-volatile "http://deb.debian.org/debian/" \
  --bootstrap-keyring "debian-archive-keyring" \
  --keyring-packages "debian-archive-keyring" \
  --security false \
  --binary-images iso-hybrid \
  --bootappend-live "boot=live components quiet splash" \
  --iso-application "LightOS" \
  --iso-volume "LightOS" \
  --iso-publisher "LightOS" \
  --compression xz \
  --debian-installer false \
  --memtest none

echo "==> Сборка образа (30-90 минут, терпеливо ждём...)"
lb build 2>&1 | tee build.log

echo ""
echo "=============================================="
echo " Готово! Образ: $(ls -1 *.iso 2>/dev/null | head -n1)"
echo "=============================================="