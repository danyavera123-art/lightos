#!/bin/bash
# LightOS: настройка системы после копирования.
# Запускается Calamares ВНУТРИ целевой системы (chroot), поэтому ROOT=/
set -eu

cd /

echo "==> Настройка целевой системы"

# --- Имя хоста ---------------------------------------------------------------
# Значение приходит из модуля users Calamares (${gs[hostname]}).
HOSTNAME_TARGET="${LIGHTOS_HOSTNAME:-}"
if [ -n "$HOSTNAME_TARGET" ] && [ "$HOSTNAME_TARGET" != "localhost" ]; then
  echo "$HOSTNAME_TARGET" > /etc/hostname
  cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_TARGET

# IPv6
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
  echo "    имя компьютера: $HOSTNAME_TARGET"
else
  echo "    имя компьютера: оставляю как есть"
fi

# --- Раскладка клавиатуры ----------------------------------------------------
# Раньше здесь безусловно писался XKBLAYOUT="us,ru", и мастер Calamares
# (модуль keyboard) оказывался бессилен — выбор пользователя затирался.
# Теперь: если модуль keyboard уже записал раскладку (всегда, т.к. он
# обязателен в sequence), не трогаем её. Файл пишем только если его нет.
if [ ! -f /etc/default/keyboard ]; then
  cat > /etc/default/keyboard <<'EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS="grp:alt_shift_toggle"
EOF
  echo "    /etc/default/keyboard не найден — записан дефолт (us)"
fi

# --- Локаль ------------------------------------------------------------------
# Тоже не затираем: если dpkg-reconfigure/locale уже отработал, оставляем.
# Гарантируем только наличие ru_RU, если система ставится на русском.
if [ ! -f /etc/default/locale ] || ! grep -q '^LANG=' /etc/default/locale 2>/dev/null; then
  echo 'LANG="ru_RU.UTF-8"' > /etc/default/locale
fi
if ! locale -a 2>/dev/null | grep -qi '^ru_RU\.utf'; then
  locale-gen ru_RU.UTF-8 >/dev/null 2>&1 || true
fi

# --- machine-id --------------------------------------------------------------
rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
systemd-machine-id-setup >/dev/null 2>&1 || true

# --- Убираем live-учётку ----------------------------------------------------
# ВАЖНО: без этого на установленной системе оставался пользователь
# `lightos` из группы sudo. Пароль live-сессии копировался вместе
# с /etc/shadow (в lightos-install-copy.sh shadow не был в исключениях),
# и вход root/lightos с этим паролем был возможен на свежей системе.
if id lightos >/dev/null 2>&1; then
  userdel -r lightos >/dev/null 2>&1 || userdel lightos >/dev/null 2>&1 || true
  groupdel lightos >/dev/null 2>&1 || true
  rm -rf /home/lightos
  rm -f /etc/sudoers.d/10-lightos-live
  rm -f /etc/lightos-live-user
  echo "    удалена live-учётка lightos"
fi
# NOPASSWD-судоер и автологин относятся только к live-сессии
rm -f /etc/sudoers.d/10-lightos-live \
      /etc/lightdm/lightdm.conf.d/10-lightos-autologin.conf 2>/dev/null || true

# Убираем живой initramfs/автологин, оставшийся от live
rm -f /etc/skel/lightos-live-user 2>/dev/null || true

# --- zram --------------------------------------------------------------------
cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

# --- Файл подкачки -----------------------------------------------------------
# Раньше файл на 1 ГБ создавался ВСЕГДА и без проверки свободного места:
# на диске в 4-5 ГБ это съедало четверть системы, а на почти полном —
# dd падал и тянул за собой весь mkswap/append в /etc/fstab.
if ! grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null; then
  AVAIL_GB=$(df -Pk / 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}' || echo 0)
  if [ "${AVAIL_GB:-0}" -ge 3 ]; then
    SWAP_MB=1024
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || true
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo "    создан /swapfile (${SWAP_MB} МБ)"
  else
    echo "    /swapfile НЕ создан: на разделе свободно ${AVAIL_GB:-0} ГБ (нужно >= 3)"
  fi
fi

# --- Службы ------------------------------------------------------------------
systemctl enable lightdm NetworkManager zramswap >/dev/null 2>&1 || true
systemctl set-default graphical.target >/dev/null 2>&1 || true

# --- Убираем live-компоненты и лишнее ----------------------------------------
# ВАЖНО: сначала помечаем загрузочные пакеты ручными. initramfs-tools
# приехал в образ как АВТО-зависимость live-boot. Как только live-* уходят,
# он становится «осиротевшим», и следующий autoremove удалял его вместе
# с /boot/initrd.img-*. Ядро оставалось, initrd пропадал — установленная
# система не грузилась вообще. Эта строка — главное исправление загрузки.
for p in initramfs-tools initramfs-tools-core kexec-tools grub-common \
         grub2-common linux-image-amd64; do
  if dpkg -s "$p" >/dev/null 2>&1; then
    apt-mark manual "$p" >/dev/null 2>&1 || true
  fi
done

apt-get purge -y live-boot live-boot-initramfs-tools live-config-sysvinit \
                    live-config-systemd live-config >/dev/null 2>&1 || true
apt-get update >/dev/null 2>&1 || true
apt-get -y autoremove --purge >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true

# Пересобираем initramfs и ПРОВЕРЯЕМ результат: без initrd система
# не загрузится, а Calamares об этом не скажет — пользователь получит
# нерабочий компьютер и ошибку только при первой перезагрузке.
KVER_TARGET="$(ls /lib/modules 2>/dev/null | sort -V | tail -1)"
update-initramfs -u >/dev/null 2>&1 || true
if [ -n "$KVER_TARGET" ]; then
  update-initramfs -u "$KVER_TARGET" >/dev/null 2>&1 || true
fi

INITRD_FOUND=0
for f in /boot/initrd.img-* /boot/initrd; do
  if [ -e "$f" ]; then INITRD_FOUND=1; fi
done
if [ "$INITRD_FOUND" -eq 1 ]; then
  echo "    initrd на месте: $(ls /boot/initrd.img-* 2>/dev/null | tr '\n' ' ')"
else
  echo "    (!) initrd НЕ найден — система не загрузится. Пересобираю принудительно..."
  if [ -n "$KVER_TARGET" ]; then
    update-initramfs -f -k "$KVER_TARGET" 2>&1 | tail -3 || true
  fi
  ls /boot/initrd.img-* >/dev/null 2>&1 \
    && echo "    initrd восстановлен" \
    || echo "    (!) initrd восстановить не удалось — обратитесь к live-системе"
fi

# --- DKMS --------------------------------------------------------------------
# Раньше ставился мета-пакет linux-headers-amd64 (≈500 МБ), который НЕ
# обязательно совпадает с текущим ядром: после обновления ядра dkms не мог
# пересобрать модуль, и Wi-Fi/Broadcom отваливался до ручного
# lightos-drivers. Теперь ставим заголовки ТОЧНО под uname -r.
KVER="$(uname -r)"
HDPKG="linux-headers-$KVER"
if dpkg -l broadcom-sta-dkms 2>/dev/null | grep -q '^ii'; then
  echo "==> Ставлю заголовки ядра $HDPKG для DKMS..."
  apt-get install -y "$HDPKG" >/dev/null 2>&1 \
    || apt-get install -y "linux-headers-amd64" >/dev/null 2>&1 \
    || echo "    (!) заголовки для $KVER не найдены — DKMS может не собраться"
  if command -v dkms >/dev/null 2>&1; then
    echo "==> Сборка DKMS-модулей..."
    dkms autoinstall 2>&1 | tail -3 || echo "    (!) dkms не собрал — починить: sudo lightos-drivers"
  fi
fi

# Мета-пакет linux-headers-* удаляем, точные заголовки оставляем: без них
# dkms не сможет пересобрать модуль при следующем обновлении ядра.
if dpkg -l linux-headers-amd64 2>/dev/null | grep -q '^ii'; then
  apt-get purge -y linux-headers-amd64 >/dev/null 2>&1 || true
  # Пакеты загрузочной цепочки уже помечены ручными выше, но повторяем
  # после autoremove: DKMS мог подтянуть что-то лишнее.
  for p in initramfs-tools initramfs-tools-core kexec-tools; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      apt-mark manual "$p" >/dev/null 2>&1 || true
    fi
  done
  apt-get -y autoremove --purge >/dev/null 2>&1 || true
fi

# Финальная пересборка initramfs после DKMS: модуль wl должен попасть
# в initrd, иначе после перезагрузки Wi-Fi не поднимется до root.
update-initramfs -u >/dev/null 2>&1 || true

# --- Настройки новых пользователей -------------------------------------------
# Раньше этот блок читал /usr/share/lightos/config/..., но install-copy
# исключает /usr/share/lightos/** — код был мёртвым и никогда не выполнялся.
# Настройки уже записаны в /etc/skel хуком 0350 на этапе сборки, так что
# здесь достаточно проверить, что они на месте.
SKEL_XFWM="/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
if [ -f "$SKEL_XFWM" ]; then
  echo "    настройки композитора для новых пользователей: OK"
else
  echo "    (!) $SKEL_XFWM отсутствует — композитор придётся выключать вручную"
fi

# Локали из live-сессии в skel не должны попасть в новых пользователей
rm -f /etc/skel/.config/lightos-firstboot.done 2>/dev/null || true

echo "==> Настройка завершена."
echo "==> Первым делом: sudo lightos-drivers   (драйверы видеокарты и Wi-Fi)"
echo "==> Затем:           sudo lightos-perf    (ускорить систему)"
exit 0
