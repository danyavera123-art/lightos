#!/bin/bash
# LightOS: настройка системы после копирования.
# Запускается Calamares ВНУТРИ целевой системы (chroot), поэтому ROOT=/
set -e

ROOT="/"
cd /

HOSTNAME="${LIGHTOS_HOSTNAME:-}"
[ -n "$HOSTNAME" ] || HOSTNAME="lightos"
echo "==> Имя компьютера: $HOSTNAME"

# --- Имя хоста ---
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

# IPv6
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# --- Раскладка и локаль ---
cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us,ru"
XKBVARIANT=""
XKBOPTIONS="grp:alt_shift_toggle"
EOF
echo 'LANG="ru_RU.UTF-8"' > /etc/default/locale
locale-gen ru_RU.UTF-8 en_US.UTF-8 2>/dev/null || true

# --- machine-id ---
rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
systemd-machine-id-setup 2>/dev/null || true

# --- zram (сжатие ОЗУ) ---
cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

# --- Файл подкачки (1 ГБ), если его ещё нет ---
if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
  dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  mkswap /swapfile 2>/dev/null || true
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- DNS (чтобы работал apt сразу после установки) ---
echo 'nameserver 1.1.1.1' > /etc/resolv.conf 2>/dev/null || true

# --- Службы ---
systemctl enable lightdm 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable zramswap 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

# Запасной вариант включения служб (просто симлинки)
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/graphical.target.wants
ln -sf /lib/systemd/system/lightdm.service         /etc/systemd/system/multi-user.target.wants/lightdm.service
ln -sf /lib/systemd/system/NetworkManager.service  /etc/systemd/system/multi-user.target.wants/NetworkManager.service
ln -sf /lib/systemd/system/zramswap.service       /etc/systemd/system/multi-user.target.wants/zramswap.service
ln -sf /lib/systemd/system/graphical.target       /etc/systemd/system/default.target

# --- Убираем live-компоненты и лишнее ---
apt-get purge -y live-boot live-boot-initramfs-tools live-config-sysvinit live-config-systemd live-config 2>/dev/null || true
apt-get update 2>/dev/null || true
apt-get -y autoremove --purge 2>/dev/null || true
apt-get clean 2>/dev/null || true

# --- Собираем DKMS-модули (broadcom-sta) -----------------------------------
# Без этого после установки Wi-Fi на Broadcom не заработает до
# первого ручного dkms autoinstall. Собираем сразу, в chroot.
echo "==> Сборка DKMS-модулей..."
if command -v dkms >/dev/null 2>&1; then
  dkms autoinstall 2>&1 | tail -5 || echo "    (!) dkms не смог собрать — починить: sudo lightos-drivers"
else
  echo "    dkms не установлен"
fi

# --- Убираем то, что нужно только при сборке --------------------------------
# linux-headers нужен для DKMS, но весит ~500 МБ. Удаляем только если
# dkms успешно собрал модули — иначе оставляем, иначе Wi-Fi не починить.
if dkms status 2>/dev/null | grep -q 'installed'; then
  apt-get purge -y linux-headers-amd64 2>/dev/null || true
  apt-get -y autoremove --purge 2>/dev/null || true
fi

# --- Пересобираем initramfs без live-компонентов ---
update-initramfs -u 2>/dev/null || true

# --- Автозапуск оптимизации при первом входе --------------------------------
mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
if [ -f /usr/share/lightos/config/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml ]; then
  cp -a /usr/share/lightos/config/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml \
        /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml 2>/dev/null || true
fi
# Убираем авто-вход live-пользователя (он и так не копируется, но на всякий случай)
rm -f /etc/sudoers.d/10-lightos-live /etc/lightdm/lightdm.conf.d/10-lightos-autologin.conf 2>/dev/null || true

echo "==> Настройка завершена."
echo "==> После первой загрузки выполните:  sudo lightos-drivers  (проверить/поставить драйверы)"
echo "==> И:                             lightos-perf.sh      (ускорить систему)"
exit 0