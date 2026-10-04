#!/bin/bash
# LightOS build script (Debian 12 + XFCE + Calamares)
#
# Запуск:
#   sudo ./build.sh                    ISO в корень репозитория
#   sudo ./build.sh --output-dir DIR   ISO в указанный каталог (для CI)
#
# После сборки: lightos.iso + SHA256SUMS
# Публикация в GitHub Releases, если есть gh и он авторизован.
# Отключить: SKIP_RELEASE=1
set -e
set -o pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

# --- Разбор аргументов -------------------------------------------------------
OUTPUT_DIR="$ROOT"
while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ -n "${2:-}" ] || { echo "--output-dir требует путь" >&2; exit 1; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"; shift ;;
    -h|--help)
      echo "Использование: sudo ./build.sh [--output-dir DIR]"
      exit 0 ;;
    *)
      echo "Неизвестный аргумент: $1" >&2
      echo "Использование: sudo ./build.sh [--output-dir DIR]" >&2
      exit 1 ;;
  esac
done

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

  # Тег — семвер, а не «latest»: кнопка «Обновить LightOS» ищет последний
  # релиз через API, и «latest» там не версия, а имя, которое невозможно
  # сравнить и переопределить при выпуске правок.
  # RELEASE_TAG задаётся извне (например, GitHub Actions подставляет свой).
  local tag="${RELEASE_TAG:-v1.0.0}"
  echo "==> Публикация $iso в GitHub Releases (tag: $tag)"

  # Пакет обновления едет вместе с ISO: без него кнопка обновления
  # на установленной системе будет бесполезна.
  local payload="$ROOT/dist-update/lightos-update-${tag#v}.tar.gz"
  local extra=()
  if [ -f "$payload" ]; then
    extra+=("$payload")
    if [ -f "$ROOT/dist-update/SHA256SUMS" ]; then
      extra+=("$ROOT/dist-update/SHA256SUMS")
    fi
  else
    echo "==> Пакет обновления не найден ($payload). Соберите его:"
    echo "    ./make-update-payload.sh ${tag#v}"
  fi

  local notes="Гибридный ISO LightOS (Debian 12 + XFCE).

Запись на флешку: Rufus (режим DD) / balenaEtcher / Ventoy.

Дальше: загрузитесь с флешки, запустите «Установить LightOS».
После установки откройте Центр приложений -> «Драйверы»."

  if gh release view "$tag" >/dev/null 2>&1; then
    echo "==> Релиз $tag уже есть — перезаписываем файлы"
    gh release upload "$tag" "$iso" "$sums" ${extra[@]+"${extra[@]}"} --clobber
    gh release edit "$tag" --notes "$notes" >/dev/null
  else
    gh release create "$tag" "$iso" "$sums" ${extra[@]+"${extra[@]}"} \
      --title "LightOS $tag" \
      --notes "$notes"
  fi
  echo "==> Релиз: $(gh release view "$tag" --json url -q .url 2>/dev/null || echo "$tag")"
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
# lb clean удаляет ТОЛЬКО живые-build каталоги (cache, chroot, lbwork,
# config/auto, config/common). Авторские файлы в config/ (package-lists,
# hooks, archives, includes.chroot) он не трогает — проверено.
# Но на всякий случай предупреждаем, если какие-то наши файлы исчезнут.
OUR_FILES_BEFORE="$(find config/package-lists config/hooks config/includes.chroot \
                        config/archives -type f 2>/dev/null | sort || true)"
lb clean 2>/dev/null || true

MISSING=""
for f in $OUR_FILES_BEFORE; do
  [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "!! ВНИМАНИЕ: lb clean удалил наши файлы:" >&2
  for f in $MISSING; do echo "   $f" >&2; done
  echo "   Отмените сборку и восстановите их: git checkout -- config/" >&2
  exit 1
fi

LB_HELP="$(lb config --help 2>&1 || true)"

DEBOOTSTRAP_OPTS=""
if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  DEBOOTSTRAP_OPTS="--keyring=/usr/share/keyrings/debian-archive-keyring.gpg"
elif [ -f /usr/share/keyrings/debian-archive-keyring.pgp ]; then
  DEBOOTSTRAP_OPTS="--keyring=/usr/share/keyrings/debian-archive-keyring.pgp"
fi

echo "==> Конфигурация live-build"
# --security/--updates НЕ передаём безусловно: в свежем live-build (на
# ubuntu-latest он именно такой, 2024-08 и новее) эти опции удалены, и lb
# падает с «unrecognized option '--updates'». У старого live-build они
# отключали несуществующий suite bookworm/updates; у нового за этот suite
# отвечает хук 0000-fix-security-suite. Ниже опции добавляются через lb_has.
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

# Эти опции есть только у старого live-build — берём их из его справки.
if lb_has --security; then
  LB_ARGS+=(--security false)
fi
if lb_has --updates; then
  LB_ARGS+=(--updates false)
fi

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

echo "==> Проверяю, что все пакеты из списка существуют в репозитории..."
# Заранее ловим опечатки в списках пакетов. live-build падает на этапе
# apt install, когда не хватает ОДНОГО пакета — через 40 минут работы.
# Дешевле проверить сейчас, до debootstrap.
#
# Скачиваем индексы один раз и ищем по ним. Обращение к packages.debian.org
# для каждого пакета отдельно — это 84 запроса и вечный бан по rate limit.
PKGLIST="$(find config/package-lists -name '*.list.chroot' -print0 2>/dev/null \
  | xargs -0 -r grep -hvE '^\s*(#|$)' 2>/dev/null \
  | sed 's/[[:space:]]*$//' | sort -u)"
PKGCOUNT="$(printf '%s\n' "$PKGLIST" | grep -c . || true)"

if command -v curl >/dev/null 2>&1; then
  echo "    пакетов в списках: $PKGCOUNT"
  TMPIDX="$(mktemp -d /tmp/lb-idx.XXXXXX)"
  # main + contrib + non-free + non-free-firmware: пакет может лежать в любой
  for suite in main contrib non-free non-free-firmware; do
    URL="http://deb.debian.org/debian/dists/bookworm/${suite}/binary-amd64/Packages.gz"
    curl -fsSL --connect-timeout 10 --max-time 120 "$URL" -o "$TMPIDX/$suite.gz" 2>/dev/null || true
  done
  if ls "$TMPIDX"/*.gz >/dev/null 2>&1; then
    cat "$TMPIDX"/*.gz 2>/dev/null | gzip -dc 2>/dev/null \
      | grep '^Package: ' | sed 's/^Package: //' | sort -u > "$TMPIDX/all.txt" 2>/dev/null || true
    if [ -s "$TMPIDX/all.txt" ]; then
      MISSING_LIST="$(printf '%s\n' "$PKGLIST" | grep . | grep -vxF -f "$TMPIDX/all.txt" || true)"
      if [ -n "$MISSING_LIST" ]; then
        echo "!! ВНИМАНИЕ: эти пакеты НЕ НАЙДЕНЫ в bookworm:" >&2
        printf '%s\n' "$MISSING_LIST" | sed 's/^/       /' >&2
        echo "   Сборка упадёт на этапе установки пакетов. Исправьте списки" >&2
        echo "   в config/package-lists/ и запустите сборку заново." >&2
        rm -rf "$TMPIDX"
        exit 1
      fi
      echo "    все $PKGCOUNT пакетов найдены в bookworm"
    else
      echo "    (индексы пустые — пропускаем проверку)"
    fi
  else
    echo "    (не удалось скачать индексы — пропускаем проверку)"
  fi
  rm -rf "$TMPIDX"
else
  echo "    (нет curl — проверку списков пропускаем)"
fi

echo "==> Сборка образа. Это долго: debootstrap 20-40 мин, установка пакетов
    60-120 мин, сжатие squashfs 40-90 мин. Итого 2.5-5 часов на слабом CPU.
    На быстром CI-раннере — около 15 минут."
lb build 2>&1 | tee build.log

ISO_SRC="$(ls -1t "$ROOT"/*.iso 2>/dev/null | head -n1 || true)"
if [ -z "$ISO_SRC" ]; then
  echo "ОШИБКА: ISO не найден после lb build. Смотри build.log" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
# Если каталог вывода — это сам корень репозитория, зовём файл lightos.iso
if [ "$(readlink -f "$OUTPUT_DIR")" = "$(readlink -f "$ROOT")" ]; then
  ISO_DST="$ROOT/lightos.iso"
else
  ISO_DST="$OUTPUT_DIR/lightos.iso"
fi

if [ "$(readlink -f "$ISO_SRC")" != "$(readlink -f "$ISO_DST")" ]; then
  mv -f "$ISO_SRC" "$ISO_DST"
fi

SHA_DST="$(dirname "$ISO_DST")/SHA256SUMS"
( cd "$(dirname "$ISO_DST")" && sha256sum "$(basename "$ISO_DST")" ) | tee "$SHA_DST"
ls -lh "$ISO_DST"

SIZE_MB=$(du -m "$ISO_DST" | cut -f1)
if [ "$SIZE_MB" -gt 2000 ]; then
  echo ""
  echo "!! ВНИМАНИЕ: ISO занимает ${SIZE_MB} МБ, а лимит GitHub Releases — 2000 МБ."
  echo "   Опубликовать такой файл не получится. Нужно ужать образ."
fi

echo ""
echo "=============================================="
echo " Готово! Образ: $ISO_DST"
echo " Размер: ${SIZE_MB} МБ"
echo "=============================================="

publish_github_release "$ISO_DST" "$SHA_DST"
