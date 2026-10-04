#!/bin/bash
# LightOS — обновление системы по кнопке, без флешки и без другого ПК
#
# Запуск:   sudo lightos-update              обновить
#           sudo lightos-update --check      только проверить, есть ли обновление
#           sudo lightos-update --rollback   откатиться на предыдущую версию
#
# Как работает:
#   1) спрашивает у GitHub Releases последний релиз LightOS
#   2) качает файл SHA256SUMS и сверяет хеш архива (защита от битой загрузки)
#   3) распаковывает в /usr/local/lib/lightos (маленький архив ~200 КБ, не весь ISO)
#   4) обновляет команды в /usr/local/bin и конфиги
#   5) при сбое — автоматический откат на предыдущую версию
#
# Важно: обновляется НЕ ядро и НЕ графический стек (для этого ISO).
#         Обновляется набор скриптов, конфигов, тем и список пакетов.
#         Ядро и пакеты обновляются отдельно кнопкой «Обновить систему».
set -u

REPO="${LIGHTOS_REPO:-danyavera123-art/lightos}"
API="https://api.github.com/repos/$REPO/releases/latest"
PREFIX_URL="https://github.com/$REPO/releases/download"
LIBDIR="/usr/local/lib/lightos"
CUR_VER_FILE="$LIBDIR/VERSION"
BACKUP_VER_FILE="$LIBDIR/VERSION.rollback"
# Резервная копия прошлой версии. ОБЯЗАТЕЛЬНО вне $TMP: временный каталог
# удаляется trap'ом при выходе, и откат в следующем запуске не нашёл бы
# ничего. Раньше он так и не работал.
CACHEDIR="/var/cache/lightos"
# Команды кладём в /usr/local/bin — туда же, куда их кладет хук установки
# (0350), и без расширения .sh. Раньше здесь стоял /usr/bin, и после первого
# обновления в системе оказывалось по две копии каждой команды.
BINDIR="/usr/local/bin"
ICON_DIR="/usr/share/icons/hicolor/128x128/apps"
DESKTOP_DIR="/usr/share/applications"

if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=''; G=''; Y=''; R=''; N=''
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s->%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '   %s[OK]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '   %s[!!]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '   %s[XX]%s %s\n' "$R" "$N" "$*" >&2; }
die()  { err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Нужен root: sudo $0"

CUR_VER="неизвестна"
[ -f "$CUR_VER_FILE" ] && CUR_VER=$(cat "$CUR_VER_FILE" | tr -d '[:space:]')

need() { command -v "$1" >/dev/null 2>&1 || die "Нет программы '$1'. Установите: sudo apt-get install -y $2"; }
need curl curl
need tar tar
need sha256sum coreutils
need mktemp coreutils

TMP=$(mktemp -d /tmp/lightos-update.XXXXXX)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Откат
# ---------------------------------------------------------------------------
rollback() {
  say ""
  local oldver=""
  [ -f "$BACKUP_VER_FILE" ] && oldver=$(tr -d '[:space:]' < "$BACKUP_VER_FILE")
  local backup="$CACHEDIR/rollback-${oldver:-unknown}.tar.gz"

  # Подстраховка: если VERSION.rollback потерялся, берём самую свежую
  # копию из кэша и восстанавливаем её версию из имени файла.
  if [ ! -f "$backup" ]; then
    backup=$(ls -1t "$CACHEDIR"/rollback-*.tar.gz 2>/dev/null | head -1)
    if [ -n "$backup" ]; then
      oldver=$(basename "$backup"); oldver=${oldver#rollback-}; oldver=${oldver%.tar.gz}
      say "    (файл с номером версии не найден, беру самую свежую копию: $oldver)"
    fi
  fi

  if [ -z "$backup" ] || [ ! -f "$backup" ]; then
    warn "Резервной копии нет — откат невозможен.
   Откатываться было не с чего: либо обновление ещё ни разу не
   выполнялось, либо копию уже удалили вручную."
    return 1
  fi

  step "Откатываюсь на версию ${oldver}..."
  if tar -xzf "$backup" --no-same-owner -C "$LIBDIR"; then
    ok "файлы LightOS возвращены на версию ${oldver}"
    # возвращаем командам исполняемость
    chmod -R a+rX "$LIBDIR" 2>/dev/null || true
    find "$LIBDIR/bin" -name 'lightos-*.sh' -exec chmod 0755 {} + 2>/dev/null || true
    while IFS= read -r f; do
      case "$f" in
        bin/lightos-*.sh)
          base=$(basename "$f")
          case "$base" in
            lightos-install-copy.sh|lightos-install-post.sh) continue ;;
          esac
          # install сквозь симлинк писал бы внутрь $LIBDIR. Заменяем
          # симлинк обычным файлом — команда не зависит от наличия LIBDIR.
          rm -f "$BINDIR/${base%.sh}" 2>/dev/null || true
          install -m 0755 "$LIBDIR/$f" "$BINDIR/${base%.sh}" 2>/dev/null
          ;;
        applications/*.desktop) install -m 0644 "$LIBDIR/$f" "$DESKTOP_DIR/$(basename "$f")" 2>/dev/null ;;
        icons/*.png)           install -m 0644 "$LIBDIR/$f" "$ICON_DIR/$(basename "$f")" 2>/dev/null ;;
      esac
    done <<< "$(tar -tzf "$backup" | sed 's|^\./||')"
    printf '%s\n' "$oldver" > "$CUR_VER_FILE"
    # Откат на «до первой версии LightOS»: файла VERSION у этой системы
    # изначально нет, возвращать слово «неизвестна» тоже незачем.
    [ "$oldver" = "неизвестна" ] && rm -f "$CUR_VER_FILE"
    rm -f "$BACKUP_VER_FILE"
    ok "откат завершён, версия теперь $oldver"
    return 0
  fi
  err "Не распаковалась резервная копия — откат не удался."
  return 1
}

# ---------------------------------------------------------------------------
# Определение последней версии
# ---------------------------------------------------------------------------
get_latest() {
  step "Спрашиваю у GitHub последний релиз LightOS..."
  local json
  if ! json=$(curl -fsSL --connect-timeout 10 --max-time 40 -H 'Accept: application/vnd.github+json' "$API" 2>/dev/null); then
    die "Не могу связаться с api.github.com.
   Нужен интернет. Проверьте подключение и повторите."
  fi

  # Нет jq — вытаскиваем поля вручную, без внешних зависимостей
  LATEST_TAG=$(printf '%s' "$json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$LATEST_TAG" ] || die "Релизы не найдены (или у репозитория ещё нет ни одного).
   Возможно, обновления ещё не опубликованы."

  # Ищем asset, который начинается с lightos-update- и заканчивается .tar.gz
  PAYLOAD_URL=$(printf '%s' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*lightos-update-[^"]*\.tar\.gz\)".*/\1/p' \
    | head -1)
  [ -n "$PAYLOAD_URL" ] || PAYLOAD_URL="$PREFIX_URL/$LATEST_TAG/lightos-update-${LATEST_TAG#v}.tar.gz"

  SUMS_URL=$(printf '%s' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*SHA256SUMS\)".*/\1/p' \
    | head -1)
  [ -n "$SUMS_URL" ] || SUMS_URL="$PREFIX_URL/$LATEST_TAG/SHA256SUMS"

  LATEST_VER="${LATEST_TAG#v}"
  ok "последний релиз: $LATEST_TAG"
}

# ---------------------------------------------------------------------------
# Сравнение версий (semver-lite: цифры через точки)
# ---------------------------------------------------------------------------
vercmp() {
  # 0 если равны, 1 если $1 новее $2, 2 если $1 старее
  # Нормализуем до трёх компонент, чтобы 1.0 и 1.0.0 считались равными.
  # Нечисловые символы (буквы, префикс v, дефис) отбрасываем,
  # поэтому "неизвестна" становится 0.0.0 и считается самой старой.
  local norm
  norm() {
    printf '%s' "$1" | tr -cd '0-9.\n' | sed 's/^\.*//; s/\.*$//' \
      | awk -F. 'BEGIN{OFS="."}
                 { a=$1; b=$2; c=$3
                   print (a==""?"0":a), (b==""?"0":b), (c==""?"0":c) }'
  }
  local a b
  a=$(norm "$1"); b=$(norm "$2")
  [ "$a" = "$b" ] && { echo 0; return; }
  if [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" = "$b" ]; then echo 1; else echo 2; fi
}

# ---------------------------------------------------------------------------
# Основной сценарий
# ---------------------------------------------------------------------------
say "  ${B}LightOS — обновление${N}"
say "    Установленная версия: ${B}${CUR_VER}${N}"
say ""

case "${1:-}" in
  --check)
    get_latest
    say ""
    case "$(vercmp "$LATEST_VER" "$CUR_VER")" in
      0) ok "Система уже последней версии ($LATEST_VER)" ;;
      1) warn "Доступно обновление: $CUR_VER -> $LATEST_VER"
          say "     Запустить:  sudo lightos-update" ;;
      *) warn "У вас версия НОВЕЕ, чем на GitHub ($CUR_VER > $LATEST_VER).
     Если это не ошибка — игнорируйте." ;;
    esac
    exit 0
    ;;
  --rollback)
    rollback
    exit 0
    ;;
  --help|-h)
    say "  Использование:"
    say "    sudo lightos-update              обновить LightOS"
    say "    sudo lightos-update --check      проверить наличие обновления"
    say "    sudo lightos-update --rollback   откатиться на предыдущую версию"
    exit 0
    ;;
  "") : ;;   # без аргументов — просто обновляемся
  *) die "Неизвестный аргумент: $1 (см. --help)" ;;
esac

get_latest

case "$(vercmp "$LATEST_VER" "$CUR_VER")" in
  0) say ""; ok "Обновлений нет — у вас уже $LATEST_VER"; exit 0 ;;
  2) say ""
      warn "У вас $CUR_VER, а на GitHub $LATEST_VER — у вас НОВЕЕ.
   Обновление пропущено. Если это не ошибка, вернитесь на старую:"
      say "     sudo lightos-update --rollback"
      exit 0 ;;
esac

say ""
step "Скачиваю обновление $CUR_VER -> $LATEST_VER..."
if ! curl -fL --progress-bar --connect-timeout 15 --max-time 300 -o "$TMP/payload.tar.gz" "$PAYLOAD_URL"; then
  err "Не скачался архив обновления"
  say "    URL: $PAYLOAD_URL"
  say "    Проверьте, что по этой ссылке в Releases есть файл lightos-update-*.tar.gz"
  exit 1
fi
ok "архив скачан ($(du -h "$TMP/payload.tar.gz" | cut -f1))"

# --- Проверка хеша ----------------------------------------------------------
step "Проверяю контрольную сумму..."
WANT=""
if curl -fsSL --connect-timeout 10 --max-time 60 -o "$TMP/SHA256SUMS" "$SUMS_URL" 2>/dev/null; then
  WANT=$(grep -E 'lightos-update-.*\.tar\.gz' "$TMP/SHA256SUMS" | awk '{print $1}' | head -1)
fi
if [ -z "$WANT" ]; then
  warn "SHA256SUMS не найден — проверку пропускаю (это небезопасно, но продолжу)"
else
  GOT=$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')
  if [ "$GOT" != "$WANT" ]; then
    err "Хеш не совпадает!
   Ожидался: $WANT
   Получено: $GOT
   Загрузка повреждена или файл подменён. Обновление отменено."
    exit 1
  fi
  ok "хеш совпал: ${GOT:0:16}..."
fi

# --- Резервная копия текущей версии ---------------------------------------
mkdir -p "$LIBDIR"
if [ -d "$LIBDIR/bin" ] || [ -d "$LIBDIR/config" ]; then
  step "Сохраняю текущую версию для отката..."
  mkdir -p "$CACHEDIR"
  # Имя — по номеру ТЕКУЩЕЙ версии, чтобы --rollback нашёл эту же копию
  BACKUP_FILE="$CACHEDIR/rollback-$CUR_VER.tar.gz"
  if tar -czf "$BACKUP_FILE" --no-same-owner -C "$LIBDIR" . 2>/dev/null; then
    ok "резервная копия: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
  else
    warn "не смог сохранить резервную копию — откат будет недоступен"
  fi
fi

# --- Распаковка ------------------------------------------------------------
step "Распаковываю в $LIBDIR..."
NEWFILES=$(tar -tzf "$TMP/payload.tar.gz" 2>/dev/null | sed 's|^\./||')
if printf '%s' "$NEWFILES" | grep -qE '(^|/)\.\.?(/|$)|^/'; then
  err "В архиве есть пути выхода за пределы каталога (/ или ..) — это попытка подмены. Отменено."
  exit 1
fi
if ! tar -xzf "$TMP/payload.tar.gz" --no-same-owner -C "$LIBDIR"; then
  err "Не распаковалось. Откатываюсь."
  rollback
  exit 1
fi
ok "файлы обновлены"

# --- Установка скриптов в PATH и на Рабочий стол ----------------------------
# install-copy и install-post нужны только во время установки (их зовёт
# Calamares/хук). На работающей системе они опасны: install-post делает
# apt purge и update-initramfs. В /usr/local/bin их не кладём.
step "Обновляю команды в $BINDIR..."
COUNT=0
while IFS= read -r f; do
  case "$f" in
    bin/lightos-*.sh)
      base=$(basename "$f")
      case "$base" in
        lightos-install-copy.sh|lightos-install-post.sh) continue ;;
      esac
      rm -f "$BINDIR/${base%.sh}" 2>/dev/null || true
      install -m 0755 "$LIBDIR/$f" "$BINDIR/${base%.sh}" && COUNT=$((COUNT+1))
      ;;
    applications/*.desktop)
      install -m 0644 "$LIBDIR/$f" "$DESKTOP_DIR/$(basename "$f")" && COUNT=$((COUNT+1))
      ;;
    icons/*.png)
      install -m 0644 "$LIBDIR/$f" "$ICON_DIR/$(basename "$f")" && COUNT=$((COUNT+1))
      ;;
  esac
done <<< "$NEWFILES"
ok "обновлено файлов: $COUNT"

# --- Пост-обновление --------------------------------------------------------
if [ -x "$LIBDIR/post-update.sh" ]; then
  step "Выполняю пост-обновление..."
  "$LIBDIR/post-update.sh" || warn "пост-обновление завершилось с ошибкой"
fi

printf '%s\n' "$LATEST_VER" > "$CUR_VER_FILE"
# Записываем версию для отката ВСЕГДА, даже если она была «неизвестна»:
# резервная копия rollback-неизвестна.tar.gz в этом случае создаётся выше,
# а раньше VERSION.rollback не появлялся — и откат, который мы сами же
# рекомендуем в конце вывода, ругался «резервной копии нет».
printf '%s\n' "$CUR_VER" > "$BACKUP_VER_FILE"

update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache -tf /usr/share/icons/hicolor 2>/dev/null || true

say ""
say "  ${G}LightOS обновлён до версии $LATEST_VER${N}"
say ""
say "  Что НЕ обновляется этой кнопкой (нужно переустановивать ISO):"
say "    * ядро Linux          — кнопка «Обновить систему» в Центре приложений"
say "    * драйверы видеокарты — кнопка «Драйверы» (или переустановка ISO)"
say "    * сам установщик Calamares"
say ""
say "  Откат:  sudo lightos-update --rollback"
say ""
exit 0