#!/bin/bash
# LightOS: копирование live-системы на целевой диск.
# Запускается Calamares в live-системе (dontChroot: true).
# Переменная ROOT указывает каталог, куда примонтирована целевая система.
set -e

ROOT="${ROOT:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "ОШИБКА: не задан ROOT (каталог целевой системы)"
  exit 1
fi
echo "==> Целевой каталог: $ROOT"

# Подмонтируем системные каталоги (нужно для chroot на следующих шагах)
mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run"
mount -t proc none "$ROOT/proc" 2>/dev/null || true
mount -t sysfs none "$ROOT/sys" 2>/dev/null || true
mount --rbind /dev "$ROOT/dev" 2>/dev/null || true
mount --rbind /run "$ROOT/run" 2>/dev/null || true

echo "==> Копирование системы (несколько минут)..."
rsync -aAX -x --info=progress2 \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/var/tmp/*' --exclude='/mnt/*' --exclude='/media/*' \
  --exclude='/lost+found' --exclude='/swapfile' \
  --exclude='/lib/live/**' \
  --exclude='/usr/share/lightos/**' \
  --exclude='/home/lightos' \
  --exclude='/root/*' \
  --exclude='/var/cache/apt/archives/*.deb' --exclude='/var/cache/apt/archives/partial/*' \
  --exclude='/var/lib/apt/lists/*' \
  --exclude='/var/log/*' \
  --exclude='/var/lib/dhcp' --exclude='/var/lib/NetworkManager' \
  --exclude='/etc/calamares' \
  --exclude='/etc/lightdm/lightdm.conf.d/10-lightos-autologin.conf' \
  --exclude='/etc/sudoers.d/10-lightos-live' \
  --exclude='/etc/machine-id' \
  --exclude='/etc/hostname' --exclude='/etc/hosts' --exclude='/etc/resolv.conf' \
  --exclude='/etc/fstab' \
  / "$ROOT/"

sync
echo "==> Копирование завершено."
exit 0