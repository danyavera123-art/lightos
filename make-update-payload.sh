#!/bin/bash
# LightOS — сборка пакета обновления для публикации в GitHub Releases.
#
# Собирает маленький архив (~200 КБ), который система забирает кнопкой
# «Обновить LightOS». Переустановка ISO для этого НЕ нужна.
#
# Запуск:   ./make-update-payload.sh              (версия из файла VERSION)
#          ./make-update-payload.sh 1.0.1        (конкретная версия)
#          ./make-update-payload.sh 1.0.1 --publish   (сразу залить в Releases)
#
# Требуется: tar, sha256sum. Для --publish ещё нужен gh CLI и вход в GitHub.
set -euo pipefail

REPO="${LIGHTOS_REPO:-danyavera123-art/lightos}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$HERE/dist-update"

VERSION="${1:-}"
# Версию берём из файла VERSION — единственного источника правды.
# Раньше она читалась grep'ом из хука 0350, и после того как версия
# переехала в отдельный файл, скрипт падал с «не задана версия».
if [ -z "$VERSION" ] && [ -f "$HERE/VERSION" ]; then
  VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"
fi

case "${2:-}" in
  --publish) PUBLISH=1 ;;
  *)          PUBLISH=0 ;;
esac

if [ -z "$VERSION" ]; then
  echo "ОШИБКА: не задана версия. Запустите:  $0 1.0.1" >&2
  echo "        или создайте файл VERSION в корне репозитория" >&2
  exit 1
fi

case "$VERSION" in
  [0-9]*.[0-9]*) : ;;
  *) echo "ОШИБКА: версия '$VERSION' не похожа на семвер (нужно 1.0.1)" >&2; exit 1 ;;
esac

command -v tar >/dev/null || { echo "ОШИБКА: нет tar" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "ОШИБКА: нет sha256sum (coreutils)" >&2; exit 1; }

echo "==> Версия: v$VERSION"
echo "==> Проверяю, что исходники на месте..."
for f in \
  VERSION \
  config/includes.chroot/usr/bin/lightos-drivers.sh \
  config/includes.chroot/usr/bin/lightos-perf.sh \
  config/includes.chroot/usr/bin/lightos-update.sh \
  config/includes.chroot/usr/bin/lightos-appcenter.sh
do
  [ -f "$HERE/$f" ] || { echo "ОШИБКА: нет файла $f" >&2; exit 1; }
done

rm -rf "$DIST"
STAGE="$DIST/stage"
mkdir -p "$STAGE/bin" "$STAGE/applications" "$STAGE/icons" "$STAGE/config"

# --- 1. Скрипты ------------------------------------------------------------
echo "==> Копирую скрипты..."
# Список задан явно. lightos-install-copy.sh сюда НЕ входит: он
# копирует live-систему на диск, и его запуск на работающей машине
# удалил бы данные. (В системе он лежит в /usr/local/lib/lightos/bin
# и вызывается только установщиком Calamares.)
for f in lightos-drivers.sh \
         lightos-perf.sh \
         lightos-update.sh \
         lightos-appcenter.sh \
         lightos-firstboot.sh \
         lightos-install-key.sh; do
  if [ -f "$HERE/config/includes.chroot/usr/bin/$f" ]; then
    install -m 0755 "$HERE/config/includes.chroot/usr/bin/$f" "$STAGE/bin/$f"
    echo "    $f"
  fi
done

# Версия едет в архиве: lightos-update кладёт её в
# /usr/local/lib/lightos/VERSION, и без неё вторая копия обновления
# не понимает, какая версия стоит.
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# --- 2. Иконки и ярлыки ----------------------------------------------------
echo "==> Копирую иконки и ярлыки..."
ICON_SRC="$HERE/config/includes.chroot/usr/share/icons/hicolor/128x128/apps"
if [ -d "$ICON_SRC" ]; then
  for ic in "$ICON_SRC"/*.png; do
    [ -f "$ic" ] && install -m 0644 "$ic" "$STAGE/icons/$(basename "$ic")"
  done
fi
if [ -f "$HERE/config/includes.chroot/usr/share/backgrounds/lightos-wallpaper.png" ]; then
  install -m 0644 "$HERE/config/includes.chroot/usr/share/backgrounds/lightos-wallpaper.png" \
                  "$STAGE/icons/"
fi

# Ярлыки берём ИЗ РЕПОЗИТОРИЯ, а не пишем здесь заново. Раньше три
# .desktop файла были захардкожены прямо в этом скрипте, и правка Exec
# в config/includes.chroot/.../applications/ на обновление не
# попадала: система продолжала запускать старое.
DESKTOP_SRC="$HERE/config/includes.chroot/usr/share/applications"
if [ ! -d "$DESKTOP_SRC" ]; then
  echo "ОШИБКА: нет каталога $DESKTOP_SRC" >&2
  exit 1
fi
for d in "$DESKTOP_SRC"/lightos-*.desktop; do
  [ -f "$d" ] || continue
  install -m 0644 "$d" "$STAGE/applications/$(basename "$d")"
  echo "    $(basename "$d")"
done

# --- 3. Конфиги (те, что система применяет) -------------------------------
echo "==> Копирую конфиги..."
SRC="$HERE/config/includes.chroot/usr/share/lightos/config/etc"
if [ -d "$SRC" ]; then
  cp -a "$SRC/." "$STAGE/config/"
fi

# --- 4. Скрипт, выполняемый после обновления ------------------------------
cat > "$STAGE/post-update.sh" <<'POSTEOF'
#!/bin/bash
# Выполняется после распаковки обновления (от root).
set -u
echo "    post-update: обновляю кэш иконок и ярлыков..."
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -tf /usr/share/icons/hicolor 2>/dev/null || true

# dkms autoinstall здесь НЕ запускаем. Если пользователь ставил
# broadcom-sta, модуль уже собран под то ядро, что было на момент
# установки. Пересборка нужна только после обновления ядра,
# а это делает apt upgrade, а не кнопка LightOS.
echo "    post-update: готово."
exit 0
POSTEOF
chmod 0755 "$STAGE/post-update.sh"

# --- 5. Архив --------------------------------------------------------------
OUT="$DIST/lightos-update-$VERSION.tar.gz"
echo "==> Собираю архив..."
tar -czf "$OUT" -C "$STAGE" .
rm -rf "$STAGE"

# Проверяем, что в архиве нет ничего лишнего: lightos-update откажется
# распаковывать файл, путь которого не попадает в белый список
# ALLOWED_TOP (bin applications icons config post-update.sh VERSION).
# Ловим это здесь, а не на стороне пользователя.
BAD=""
while IFS= read -r entry; do
  top="${entry#./}"; top="${top%%/*}"
  case "$top" in
    bin|applications|icons|config|post-update.sh|VERSION) : ;;
    *) BAD="$BAD $entry" ;;
  esac
done < <(tar -tzf "$OUT")
if [ -n "$BAD" ]; then
  echo "ОШИБКА: в архиве есть файлы вне белого списка:" >&2
  for b in $BAD; do echo "       $b" >&2; done
  echo "   lightos-update отклонит такой архив." >&2
  exit 1
fi

echo "==> Считаю контрольную сумму..."
( cd "$DIST" && sha256sum "lightos-update-$VERSION.tar.gz" > SHA256SUMS )

# --- 6. Подпись GPG (если задан секретный ключ) ----------------------------
# Если приватный ключ доступен, подписываем SHA256SUMS: тогда
# lightos-update с установленным ключом проверит подпись, а без ключа
# просто сверит хеш и спросит подтверждение вручную.
SIGNING_KEY="${LIGHTOS_SIGNING_KEY:-${GPG_SIGNING_KEY:-}}"
SIGNED=0
if [ -n "$SIGNING_KEY" ] && command -v gpg >/dev/null 2>&1; then
  echo "==> Подписываю SHA256SUMS ключом $SIGNING_KEY..."
  rm -f "$DIST/SHA256SUMS.asc"
  if gpg --batch --yes --local-user "$SIGNING_KEY" \
         --armor --detach-sign --output "$DIST/SHA256SUMS.asc" \
         "$DIST/SHA256SUMS" 2>"$DIST/gpg.err"; then
    SIGNED=1
    echo "    подпись создана"
  else
    echo "!! Не удалось подписать (продолжаю без подписи):" >&2
    [ -f "$DIST/gpg.err" ] && sed 's/^/   /' "$DIST/gpg.err" >&2
    rm -f "$DIST/SHA256SUMS.asc"
  fi
elif [ -n "$SIGNING_KEY" ]; then
  echo "!! Задан ключ $SIGNING_KEY, но gpg не установлен — подписи не будет" >&2
else
  echo "==> Ключ подписи не задан (LIGHTOS_SIGNING_KEY), SHA256SUMS будет без подписи."
  echo "    Система сверит хеш и попросит подтвердить установку вручную."
fi

SIZE=$(du -h "$OUT" | cut -f1)
echo ""
echo "  Готово:"
ls -l "$DIST" | grep -v '^total' | sed 's/^/    /'
echo ""
echo "    Размер архива: $SIZE"
echo ""
if [ "$SIGNED" -eq 1 ]; then
  echo "  Подпись: SHA256SUMS.asc — загрузите ЕЁ тоже, иначе lightos-update"
  echo "  с установленным ключом откажется обновляться."
  echo ""
fi
echo "  Загрузить в релиз v$VERSION:"
echo "    gh release create v$VERSION --repo $REPO \\"
echo "      dist-update/lightos-update-$VERSION.tar.gz \\"
echo "      dist-update/SHA256SUMS \\"
if [ "$SIGNED" -eq 1 ]; then
echo "      dist-update/SHA256SUMS.asc \\"
fi
echo "      --title \"LightOS v$VERSION\""
echo ""
echo "  Либо перетащите файлы на страницу релиза на GitHub."
echo ""

if [ "$PUBLISH" -eq 1 ]; then
  command -v gh >/dev/null || { echo "ОШИБКА: нет gh CLI. Установите или загрузите файлы вручную." >&2; exit 1; }
  echo "==> Публикую в Releases (нужен gh auth login)..."
  ASSETS=("$OUT" "$DIST/SHA256SUMS")
  [ "$SIGNED" -eq 1 ] && ASSETS+=("$DIST/SHA256SUMS.asc")
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "${ASSETS[@]}" --repo "$REPO" --clobber
  else
    gh release create "v$VERSION" "${ASSETS[@]}" \
      --repo "$REPO" \
      --title "LightOS v$VERSION" \
      --notes "Обновление LightOS. Кнопка «Обновить LightOS» в Центре приложений."
  fi
  echo "==> Опубликовано: https://github.com/$REPO/releases/tag/v$VERSION"
fi

exit 0