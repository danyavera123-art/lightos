#!/bin/bash
# LightOS build script (Debian 12 + XFCE + Calamares)
# Запуск: sudo ./build.sh
# После сборки: lightos.iso
# Публикация в GitHub Releases, если есть gh. Отключить: SKIP_RELEASE=1
set -e
set -o pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти от root: sudo ./build.sh" >&2
  exit 1
fi

strip_crlf() {
  find config/hooks config/includes.chroot/usr/bin build.sh \
    -type f \( -name '*.sh' -o -name '*.hook.chroot' -o -name '*.hook.chroot_early' -o -name '*.hook.binary' \) \
    -print0 2>/dev/null | xargs -0 -r sed -i 's/\r$//'
}

need_host_cmds() {
  local missing=0
  local cmd
  for cmd in lb debootstrap xorriso mksquashfs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Нет команды: $cmd" >&2
      missing=1
    fi
  done
  if [ ! -f /usr/share/keyrings/debian-archive-keyring.gpg ] && [ ! -f /usr/share/keyrings/debian-archive-keyring.pgp ]; then
    echo "Нет debian-archive-keyring (пакет debian-archive-keyring)" >&2
    missing=1
  fi
  if [ "$missing" -ne 0 ]; then
    echo "Установи зависимости:" >&2
    echo "  apt-get install -y live-build debootstrap debian-archive-keyring xorriso isolinux syslinux-common squashfs-tools mtools dosfstools grub-efi-amd64-bin grub-pc-bin ca-certificates" >&2
    exit 1
  fi
}

# live-build на Ubuntu 22.04 и Debian 12 имеют разные имена опций
lb_has() {
  printf '%s' "$LB_HELP" | grep -F -q -- "$1"
}

publish_github_release() {
  local iso="$1"
  local sums="$2"
  if [ "${SKIP_RELEASE:-0}" = "1" ]; then
    echo "==> SKIP_RELEASE=1 — релиз на GitHub не публикуем"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "==> gh не установлен — пропуск публикации релиза"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "==> gh не авторизован — пропуск публикации релиза"
    return 0
  fi

  echo "==> Публикация $iso в GitHub Releases (tag: latest)"
  if gh release view latest >/dev/null 2>&1; then
    gh release upload latest "$iso" "$sums" --clobber
  else
    gh release create latest "$iso" "$sums" \
      --title "LightOS" \
      --notes "Гибридный ISO LightOS (Debian 12 + XFCE). Запись: Rufus (DD) / balenaEtcher / Ventoy." \
      --latest
  fi
  echo "==> Релиз: $(gh release view latest --json url -q .url 2>/dev/null || echo latest)"
}

strip_crlf
chmod -R +x config/hooks config/includes.chroot/usr/bin 2>/dev/null || true
chmod -R +x config/includes.chroot/etc/skel 2>/dev/null || true
chmod +x config/includes.chroot/etc/skel/.config/autostart/lightos-firstboot.desktop 2>/dev/null || true

need_host_cmds

CACHE_PACKAGES=true
if [ "${CI:-}" = "true" ]; then
  CACHE_PACKAGES=false
fi

echo "==> Очистка предыдущей сборки (если есть)"
lb clean 2>/dev/null || true

LB_HELP="$(lb config --help 2>&1 || true)"

DEBOOTSTRAP_OPTS=""
if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  DEBOOTSTRAP_OPTS="--keyring=/usr/share/keyrings/debian-archive-keyring.gpg"
elif [ -f /usr/share/keyrings/debian-archive-keyring.pgp ]; then
  DEBOOTSTRAP_OPTS="--keyring=/usr/share/keyrings/debian-archive-keyring.pgp"
fi

echo "==> Конфигурация live-build"
# --security/--updates false: старый live-build пишет несуществующий suite bookworm/updates.
# Правильные репозитории: config/archives/*.list.{chroot,binary}
LB_ARGS=(
  --distribution bookworm
  --system live
  --linux-flavours amd64
  --archive-areas "main contrib non-free-firmware"
  --mirror-bootstrap "http://deb.debian.org/debian/"
  --mirror-chroot "http://deb.debian.org/debian/"
  --mirror-chroot-security "http://security.debian.org/debian-security/"
  --mirror-binary "http://deb.debian.org/debian/"
  --mirror-binary-security "http://security.debian.org/debian-security/"
  --bootstrap-keyring "debian-archive-keyring"
  --security false
  --updates false
  --source false
  --cache-packages "$CACHE_PACKAGES"
  --apt-indices false
  --initramfs live-boot
  --iso-application "LightOS"
  --iso-volume "LightOS"
  --iso-publisher "LightOS"
  --debian-installer false
  --memtest none
  --bootappend-live "boot=live components quiet splash"
)

if lb_has --mode; then
  LB_ARGS+=(--mode debian)
fi
if lb_has --architectures; then
  LB_ARGS+=(--architectures amd64)
else
  LB_ARGS+=(--architecture amd64)
fi
if lb_has --binary-images; then
  LB_ARGS+=(--binary-images iso-hybrid)
else
  LB_ARGS+=(--binary-image iso-hybrid)
fi
if lb_has --linux-packages; then
  LB_ARGS+=(--linux-packages "linux-image")
fi
if lb_has --parent-mirror-bootstrap; then
  LB_ARGS+=(
    --parent-mirror-bootstrap "http://deb.debian.org/debian/"
    --parent-mirror-chroot "http://deb.debian.org/debian/"
    --parent-mirror-chroot-security "http://security.debian.org/debian-security/"
    --parent-mirror-binary "http://deb.debian.org/debian/"
    --parent-mirror-binary-security "http://security.debian.org/debian-security/"
  )
fi
if lb_has --parent-mirror-chroot-volatile; then
  LB_ARGS+=(
    --parent-mirror-chroot-volatile "http://deb.debian.org/debian/"
    --parent-mirror-binary-volatile "http://deb.debian.org/debian/"
    --mirror-chroot-volatile "http://deb.debian.org/debian/"
    --mirror-binary-volatile "http://deb.debian.org/debian/"
  )
fi
if lb_has --keyring-packages; then
  LB_ARGS+=(--keyring-packages "debian-archive-keyring")
fi
if lb_has --debootstrap-options && [ -n "$DEBOOTSTRAP_OPTS" ]; then
  LB_ARGS+=(--debootstrap-options "$DEBOOTSTRAP_OPTS")
fi
if lb_has --backports; then
  LB_ARGS+=(--backports false)
fi
if lb_has --apt-source-archives; then
  LB_ARGS+=(--apt-source-archives false)
fi
if lb_has --firmware-binary; then
  LB_ARGS+=(--firmware-binary false)
fi
if lb_has --firmware-chroot; then
  LB_ARGS+=(--firmware-chroot true)
fi
if lb_has --win32-loader; then
  LB_ARGS+=(--win32-loader false)
fi
if lb_has --uefi-secure-boot; then
  LB_ARGS+=(--uefi-secure-boot disable)
fi
if lb_has --initsystem; then
  LB_ARGS+=(--initsystem systemd)
fi
if lb_has --zsync; then
  LB_ARGS+=(--zsync false)
fi
if printf '%s' "$LB_HELP" | grep -q -- '|xz|'; then
  LB_ARGS+=(--compression xz)
elif lb_has --compression; then
  LB_ARGS+=(--compression gzip)
fi
if lb_has --image-name; then
  LB_ARGS+=(--image-name lightos)
fi

lb config "${LB_ARGS[@]}"

echo "==> Сборка образа (30-90 минут)..."
lb build 2>&1 | tee build.log

ISO_SRC="$(ls -1t "$ROOT"/*.iso 2>/dev/null | head -n1 || true)"
if [ -z "$ISO_SRC" ]; then
  echo "ОШИБКА: ISO не найден после lb build. Смотри build.log" >&2
  exit 1
fi

ISO_DST="$ROOT/lightos.iso"
if [ "$(readlink -f "$ISO_SRC")" != "$(readlink -f "$ISO_DST")" ]; then
  mv -f "$ISO_SRC" "$ISO_DST"
fi

sha256sum "$ISO_DST" | tee "$ROOT/SHA256SUMS"
ls -lh "$ISO_DST"

echo ""
echo "=============================================="
echo " Готово! Образ: $ISO_DST"
echo "=============================================="

publish_github_release "$ISO_DST" "$ROOT/SHA256SUMS"
