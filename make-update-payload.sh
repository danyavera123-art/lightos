#!/bin/bash
# LightOS — сборка пакета обновления для публикации в GitHub Releases.
#
# Собирает из config/ маленький архив (~200 КБ), который система
# забирает кнопкой «Обновить LightOS». Переустановка ISO для этого
# НЕ нужна.
#
# Запуск:   ./make-update-payload.sh              (версия из VERSION)
#          ./make-update-payload.sh 1.0.1        (конкретная версия)
#          ./make-update-payload.sh 1.0.1 --publish   (сразу залить в Releases)
#
# Требуется: tar, sha256sum. Для --publish ещё нужен gh CLI и доступ к GitHub.
set -euo pipefail

REPO="danyavera123-art/lightos"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="$HERE/dist-update"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  # Версию берём из hook, где она объявлена, — чтобы не расходились
  VERSION=$(grep -oP '^VERSION="\K[^"]+' "$HERE/config/hooks/live/0350-lightos-scripts.hook.chroot" | head -1)
fi

case "${2:-}" in
  --publish) PUBLISH=1 ;;
  *)          PUBLISH=0 ;;
esac

if [ -z "$VERSION" ]; then
  echo "ОШИБКА: не задана версия. Запустите:  $0 1.0.1" >&2
  exit 1
fi

command -v tar >/dev/null || { echo "ОШИБКА: нет tar" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "ОШИБКА: нет sha256sum (coreutils)" >&2; exit 1; }

echo "==> Версия: v$VERSION"
echo "==> Проверяю, что исходники на месте..."
for f in \
  config/hooks/live/0350-lightos-scripts.hook.chroot \
  config/includes.chroot/usr/bin/lightos-drivers.sh \
  config/includes.chroot/usr/bin/lightos-perf.sh \
  config/includes.chroot/usr/bin/lightos-update.sh \
  config/includes.chroot/usr/bin/lightos-appcenter.sh
do
  [ -f "$HERE/$f" ] || { echo "ОШИБКА: нет файла $f" >&2; exit 1; }
done

rm -rf "$DIST"
STAGE="$DIST/stage"
mkdir -p "$STAGE/bin" "$STAGE/applications" "$STAGE/config"

# --- 1. Скрипты ------------------------------------------------------------
echo "==> Копирую скрипты..."
for f in lightos-drivers.sh lightos-perf.sh lightos-update.sh \
         lightos-appcenter.sh lightos-firstboot.sh lightos-install-post.sh; do
  [ -f "$HERE/config/includes.chroot/usr/bin/$f" ] || continue
  install -m 0755 "$HERE/config/includes.chroot/usr/bin/$f" "$STAGE/bin/$f"
done

# --- 2. Иконки и ярлыки ----------------------------------------------------
echo "==> Копирую иконки и ярлыки..."
ICON_SRC="$HERE/config/includes.chroot/usr/share/icons/hicolor/128x128/apps"
[ -d "$ICON_SRC" ] && cp -a "$ICON_SRC/." "$STAGE/icons/" 2>/dev/null || mkdir -p "$STAGE/icons"
for ic in "$ICON_SRC"/*.png; do
  [ -f "$ic" ] && install -m 0644 "$ic" "$STAGE/icons/$(basename "$ic")"
done
install -m 0644 "$HERE/config/includes.chroot/usr/share/backgrounds/lightos-wallpaper.png" \
                "$STAGE/icons/" 2>/dev/null || true

mkdir -p "$STAGE/applications"
cat > "$STAGE/applications/lightos-drivers.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Драйверы
Comment=Найти и поставить драйверы видеокарты, Wi-Fi и звука
Exec=x-terminal-emulator -e sudo lightos-drivers
Icon=lightos-logo
Terminal=false
Categories=System;
EOF
cat > "$STAGE/applications/lightos-perf.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Оптимизация системы
Comment=Отключить композитор и анимации — ускорить систему
Exec=xfce4-terminal --title="Оптимизация LightOS" --maximize --command="lightos-perf.sh"
Icon=lightos-logo
Terminal=false
Categories=System;
EOF
cat > "$STAGE/applications/lightos-update.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Обновить LightOS
Comment=Обновить LightOS через интернет, без флешки и без другого компьютера
Exec=xfce4-terminal --title="Обновление LightOS" --maximize --command="sudo lightos-update.sh"
Icon=lightos-logo
Terminal=false
Categories=System;
EOF
chmod 0644 "$STAGE"/applications/*.desktop

# --- 3. Конфиги (те, что система применяет) -------------------------------
echo "==> Копирую конфиги..."
SRC="$HERE/config/includes.chroot/usr/share/lightos/config/etc"
if [ -d "$SRC" ]; then
  cp -a "$SRC/." "$STAGE/config/"
fi

# --- 4. Скрипт, выполняемый после обновления ------------------------------
cat > "$STAGE/post-update.sh" <<'EOF'
#!/bin/bash
# Выполняется после распаковки обновления (от root).
set -u
echo "    post-update: обновляю кэш иконок и ярлыков..."
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -tf /usr/share/icons/hicolor 2>/dev/null || true
if command -v dkms >/dev/null; then
  echo "    post-update: DKMS-модули..."
  dkms autoinstall 2>&1 | tail -3 || true
fi
echo "    post-update: готово."
exit 0
EOF
chmod 0755 "$STAGE/post-update.sh"

# --- 5. Архив --------------------------------------------------------------
OUT="$DIST/lightos-update-$VERSION.tar.gz"
echo "==> Собираю архив..."
tar -czf "$OUT" -C "$STAGE" .
rm -rf "$STAGE"

echo "==> Считаю контрольную сумму..."
( cd "$DIST" && sha256sum "lightos-update-$VERSION.tar.gz" > SHA256SUMS )

SIZE=$(du -h "$OUT" | cut -f1)
echo ""
echo "  Готово:"
ls -l "$DIST" | grep -v '^total' | sed 's/^/    /'
echo ""
echo "    Размер архива: $SIZE"
echo ""
echo "  Что с этим делать — ЗАГРУЗИТЬ В РЕЛИЗ v$VERSION:"
echo "    gh release create v$VERSION \\"
echo "      dist-update/lightos-update-$VERSION.tar.gz \\"
echo "      dist-update/SHA256SUMS \\"
echo "      --repo $REPO \\"
echo "      --title \"LightOS v$VERSION\" \\"
echo "      --notes \"Обновление LightOS. Кнопка «Обновить LightOS» в Центре приложений.\""
echo ""
echo "  Либо просто перетащите оба файла на страницу релиза на GitHub."
echo ""

if [ "$PUBLISH" -eq 1 ]; then
  command -v gh >/dev/null || { echo "ОШИБКА: нет gh CLI. Установите или загрузите файлы вручную." >&2; exit 1; }
  echo "==> Публикую в Releases (нужен gh auth login)..."
  gh release create "v$VERSION" \
    "$OUT" "$DIST/SHA256SUMS" \
    --repo "$REPO" \
    --title "LightOS v$VERSION" \
    --notes "Обновление LightOS. Кнопка «Обновить LightOS» в Центре приложений."
  echo "==> Опубликовано: https://github.com/$REPO/releases/tag/v$VERSION"
fi

exit 0