#!/bin/bash
# LightOS: копирование live-системы на целевой диск.
# Запускается Calamares в live-системе (dontChroot: true).
# Переменная ROOT указывает каталог, куда смонтирована целевая система.
set -e

ROOT="${ROOT:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "ОШИБНО: не задан ROOT (каталог целевой системы)"
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
# ВАЖНО про учётные данные: пароли из live-сессии копировать нельзя.
# В live у пользователя lightos стоял известный пароль, и /etc/shadow
# попадал на диск вместе с ним — то есть на свежей системе был рабочий
# вход с паролем live-сессии. Модуль users Calamares создаёт нового
# пользователя уже ПОСЛЕ копирования, но полагаться на этот порядок
# нельзя: при любом сбое между copy и users живой вход остаётся.
# Поэтому shadow/gshadow копируются, но тут же САНИРУЮТСЯ: все
# учётные записи с UID >= 1000 удаляются, системные (UID < 1000)
# остаются с заблокированным паролем. Нового пользователя создаст
# модуль users.
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
  --exclude='/etc/lightos-live-user' \
  --exclude='/etc/machine-id' \
  --exclude='/etc/hostname' --exclude='/etc/hosts' --exclude='/etc/resolv.conf' \
  --exclude='/etc/fstab' \
  --exclude='/etc/shadow-*.lock' \
  / "$ROOT/"

echo "==> Санирую учётные данные..."
sanitize_shadow() {
  local src="$1" dst="$2" mode="$3"
  [ -f "$src" ] || { : > "$dst"; chmod "$mode" "$dst"; return 0; }
  # Оставляем только системные записи (UID < 1000) с заблокированным паролем.
  awk -F: '{
      if ($3 != "" && $3 + 0 < 1000) {
        $2 = "!"
        print $1":"$2":"$3":"$4":"$5":"$6":"$7":"$8":"$9
      }
    }' "$src" > "$dst.tmp"
  mv -f "$dst.tmp" "$dst"
  chmod "$mode" "$dst"
}
sanitize_shadow "$ROOT/etc/shadow"  "$ROOT/etc/shadow"  640
sanitize_shadow "$ROOT/etc/gshadow" "$ROOT/etc/gshadow" 640
rm -f "$ROOT/etc/shadow-" "$ROOT/etc/gshadow-" 2>/dev/null || true

# Убираем live-учётку из passwd/group, чтобы она не осталась в системе даже
# без пароля (модуль users её не перезаписывает — он добавляет нового).
if grep -q '^lightos:' "$ROOT/etc/passwd" 2>/dev/null; then
  sed -i '/^lightos:/d' "$ROOT/etc/passwd" || true
  rm -rf "$ROOT/home/lightos"
  echo "    удалён live-пользователь из /etc/passwd"
fi
sed -i '/^lightos:/d' "$ROOT/etc/group" 2>/dev/null || true

sync
echo "==> Копирование завершено."
exit 0
