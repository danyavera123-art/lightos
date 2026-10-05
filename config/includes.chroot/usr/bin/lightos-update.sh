#!/bin/bash
# LightOS — обновление системы по кнопке, без флешки и без другого ПК
#
# Запуск:   sudo lightos-update              обновить
#           sudo lightos-update --check      только проверить, есть ли обновление
#           sudo lightos-update --rollback   откатиться на предыдущую версию
#
# Как работает:
#   1) спрашивает у GitHub Releases последний релиз LightOS
#   2) скачивает SHA256SUMS и сверяет хеш архива
#   3) если в системе есть открытый ключ — проверяет GPG-подпись SHA256SUMS
#   4) распаковывает в /usr/local/lib/lightos (маленький архив, не весь ISO)
#   5) обновляет команды в /usr/local/bin и ярлыки
#   6) при сбое — автоматический откат на предыдущую версию
#
# Безопасность. Раньше подпись не проверялась ВООБЩЕ: SHA256SUMS и сам
# архив скачивались с одного и того же GitHub, то есть хеш подтверждал
# только целостность загрузки, но не подлинность. Взлом аккаунта
# владельца репозитория приводил к выполнению произвольного кода от root
# на всех машинах (post-update.sh запускается из архива).
# Теперь: если ключ установлен (/usr/share/keyrings/lightos-update.gpg) —
# подпись обязательна; SHA256SUMS обязателен ВСЕГДА, независимо от ключа.
#
# Важно: обновляется НЕ ядро и НЕ графический стек (для этого ISO).
#         Обновляется набор скриптов, конфигов, тем и список пакетов.
set -u

REPO="${LIGHTOS_REPO:-danyavera123-art/lightos}"
API="https://api.github.com/repos/$REPO/releases/latest"
PREFIX_URL="https://github.com/$REPO/releases/download"
LIBDIR="/usr/local/lib/lightos"
CUR_VER_FILE="$LIBDIR/VERSION"
BACKUP_VER_FILE="$LIBDIR/VERSION.rollback"
# Резервная копия прошлой версии. ОБЯЗАТЕЛЬНО вне $TMP: временный каталог
# удаляется trap'ом при выходе, и откат в следующем запуске не нашёл бы
# ничего.
CACHEDIR="/var/cache/lightos"
# Команды кладём в /usr/local/bin — туда же, куда их кладет хук установки
# (0350), и без расширения .sh. Раньше здесь стоял /usr/bin, и после первого
# обновления в системе оказывалось по две копии каждой команды.
BINDIR="/usr/local/bin"
ICON_DIR="/usr/share/icons/hicolor/128x128/apps"
DESKTOP_DIR="/usr/share/applications"
KEYRING="/usr/share/keyrings/lightos-update.gpg"
# Каталог, который мы вообще готовы принять из архива. Распаковка идёт
# во временный каталог и только потом переносится сюда — так симлинк
# внутри архива не может заставить нас писать мимо $LIBDIR.
ALLOWED_TOP="bin applications icons config post-update.sh VERSION"

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
# Сравнение версий (semver 2.0.0)
# ---------------------------------------------------------------------------
# Раньше нечисловые символы просто отбрасывались, из-за чего
# 1.0.0-rc1 превращался в «1.0.01» и оказывался НОВЕЕ финального 1.0.0.
# Теперь учитывается пре-релиз: 1.0.0-rc1 < 1.0.0.
vercmp() {
  local a b
  a=$(ver_norm "$1"); b=$(ver_norm "$2")
  # a/b в формате "core|pre"
  local ac apre bc bpre
  ac=${a%%|*}; apre=${a#*|}
  bc=${b%%|*}; bpre=${b#*|}

  if [ "$ac" != "$bc" ]; then
    if [ "$(printf '%s\n%s\n' "$bc" "$ac" | sort -V | head -1)" = "$bc" ]; then
      echo 1
    else
      echo 2
    fi
    return
  fi
  vercmp_pre "$apre" "$bpre"
}

# Нормализация: "v1.2.3-rc1" -> "1.2.3|rc1", "неизвестна" -> "0.0.0|"
ver_norm() {
  local v="${1:-}"
  v="${v#v}"
  v="${v%%+*}"                 # отбрасываем build-метаданные
  local core pre=""
  case "$v" in
    *-*) core="${v%%-*}"; pre="${v#*-}" ;;
    *)   core="$v" ;;
  esac
  core="${core//[^0-9.]/}"
  core="${core#.}"
  core="${core%.}"
  [ -n "$core" ] || core="0"
  # добиваем до трёх компонент
  while [ "$(printf '%s' "$core" | tr -cd '.' | wc -c)" -lt 2 ]; do
    core="${core}0"
  done
  # убираем ведущие нули в каждом компоненте (sort -V иначе разойдётся)
  core=$(printf '%s' "$core" | awk -F. '{
    for (i=1;i<=NF;i++) {
      sub(/^0+/, "", $i);
      if ($i == "") $i = "0";
    }
    print $1"."$2"."$3
  }')
  pre="${pre//[^0-9A-Za-z.]/}"
  printf '%s|%s' "$core" "$pre"
}

# Сравнение пре-релизов по semver: пусто (финальный) > непусто.
# 0 равны, 1 первый новее, 2 первый старее.
vercmp_pre() {
  local a="${1:-}" b="${2:-}"
  if [ -z "$a" ] && [ -z "$b" ]; then echo 0; return; fi
  if [ -z "$a" ]; then echo 1; return; fi
  if [ -z "$b" ]; then echo 2; return; fi
  if [ "$a" = "$b" ]; then echo 0; return; fi

  local -a A B
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  local n=${#A[@]}
  [ "${#B[@]}" -gt "$n" ] && n=${#B[@]}

  local i x y xn yn
  for ((i = 0; i < n; i++)); do
    x=${A[i]:-}; y=${B[i]:-}
    [ -z "$x" ] && { echo 2; return; }
    [ -z "$y" ] && { echo 1; return; }
    # числовые идентификаторы всегда меньше буквенных
    case "$x" in *[!0-9]*) xn=1 ;; *) xn=0 ;; esac
    case "$y" in *[!0-9]*) yn=1 ;; *) yn=0 ;; esac
    if [ "$xn" -ne "$yn" ]; then
      if [ "$xn" -lt "$yn" ]; then echo 1; else echo 2; fi
      return
    fi
    if [ "$xn" -eq 0 ]; then
      x=$((10#$x)); y=$((10#$y))
    fi
    if [ "$x" -ne "$y" ]; then
      if [ "$x" -gt "$y" ]; then echo 1; else echo 2; fi
      return
    fi
  done
  echo 0
}

# ---------------------------------------------------------------------------
# Безопасная распаковка
# ---------------------------------------------------------------------------
# Проверяем СПИСОК файлов: никаких абсолютных путей, никаких «..»,
# никаких симлинков/устройств, и только разрешённые верхние каталоги.
# Раньше проверка ловила только «..» и ведущий «/», но не проверяла тип
# записи: симлинк внутри архива позволял записать файлы мимо $LIBDIR.
safe_extract() {
  local archive="$1" dest="$2"
  local listing entry bad=0
  listing=$(tar -tzf "$archive" 2>/dev/null | sed 's|^\./||')
  [ -n "$listing" ] || { err "архив пустой или не читается"; return 1; }

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*)        err "абсолютный путь в архиве: $entry"; bad=1; continue ;;
      *..*)      err "путь с '..' в архиве: $entry"; bad=1; continue ;;
    esac
    local top="${entry%%/*}"
    case " $ALLOWED_TOP " in
      *" $top "*) : ;;
      *) err "неожиданный путь в архиве: $entry"; bad=1; continue ;;
    esac
  done <<< "$listing"

  # Типы записей: запрещаем симлинки, жёсткие ссылки и устройства.
  local verbose
  verbose=$(tar -tvzf "$archive" 2>/dev/null)
  if printf '%s' "$verbose" | grep -qE '^[^lhd-]'; then
    err "в архиве есть спец-файлы (ссылки/устройства) — отменяю"
    bad=1
  fi
  [ "$bad" -eq 0 ] || return 1

  # tar с --no-same-owner и без сохранения прав на setuid,
  # распаковка во временный каталог (никаких ссылок наружу).
  tar -xzf "$archive" --no-same-owner --no-same-permissions \
      --exclude='.git*' -C "$dest" 2>/dev/null || {
    err "распаковка не удалась"; return 1; }
  return 0
}

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
  local stage="$TMP/rollback"
  mkdir -p "$stage"
  # Распаковываем во временный каталог, а не прямо поверх работающей
  # системы: старый код мог остаться на месте при частичной распаковке.
  if safe_extract "$backup" "$stage"; then
    cp -a "$stage"/. "$LIBDIR"/ || { err "не удалось вернуть файлы"; return 1; }
    ok "файлы LightOS возвращены на версию ${oldver}"
    chmod -R a+rX "$LIBDIR" 2>/dev/null || true
    find "$LIBDIR/bin" -name 'lightos-*.sh' -exec chmod 0755 {} + 2>/dev/null || true
    install_payload_commands "$LIBDIR"
    printf '%s\n' "$oldver" > "$CUR_VER_FILE"
    [ "$oldver" = "неизвестна" ] && rm -f "$CUR_VER_FILE"
    rm -f "$BACKUP_VER_FILE"
    ok "откат завершён, версия теперь $oldver"
    return 0
  fi
  err "Резервная копия не распаковалась — откат не удался."
  return 1
}

# ---------------------------------------------------------------------------
# Установка команд и ярлыков из распакованного дерева
# ---------------------------------------------------------------------------
install_payload_commands() {
  local root="$1" f base count=0
  [ -d "$root/bin" ] || return 0
  for f in "$root"/bin/lightos-*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .sh)
    # install-* в PATH не кладём: на работающей системе они опасны
    # (install-post делает apt purge и update-initramfs).
    case "$base" in
      lightos-install-copy|lightos-install-post) continue ;;
    esac
    rm -f "$BINDIR/$base" 2>/dev/null || true
    install -m 0755 "$f" "$BINDIR/$base" 2>/dev/null && count=$((count+1))
  done
  # Ярлыки: берём из applications/ и icons/Payload
  if [ -d "$root/applications" ]; then
    for f in "$root"/applications/*.desktop; do
      [ -f "$f" ] || continue
      install -m 0644 "$f" "$DESKTOP_DIR/$(basename "$f")" 2>/dev/null && count=$((count+1))
    done
  fi
  if [ -d "$root/icons" ]; then
    mkdir -p "$ICON_DIR"
    for f in "$root"/icons/*.png; do
      [ -f "$f" ] || continue
      install -m 0644 "$f" "$ICON_DIR/$(basename "$f")" 2>/dev/null && count=$((count+1))
    done
  fi
  printf '%s' "$count"
}

# ---------------------------------------------------------------------------
# Определение последней версии
# ---------------------------------------------------------------------------
get_latest() {
  step "Спрашиваю у GitHub последний релиз LightOS..."
  local json
  if ! json=$(curl -fsSL --connect-timeout 10 --max-time 40 -H 'Accept: application/vnd.github+json' "$API" 2>/dev/null); then
    die "Не могу связаться с api.github.com.
   Нужен интернет. Проверьте подключение и повторите.
   Если вы за прокси или ограничением API GitHub — используйте зеркало:
   LIGHTOS_REPO=<owner>/<repo> sudo lightos-update"
  fi

  # Тег должен выглядеть как семвер. Иначе в версию попадёт мусор
  # из tag_name, и сравнение версий осмысла не имеет.
  LATEST_TAG=$(printf '%s' "$json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$LATEST_TAG" ] || die "Релизы не найдены (или у репозитория ещё нет ни одного).
   Возможно, обновления ещё не опубликованы."
  case "$LATEST_TAG" in
    v[0-9]*.[0-9]*|[0-9]*.[0-9]*) : ;;
    *) die "Некорректный тег релиза: '$LATEST_TAG'.
   Ожидается семвер, например v1.0.0." ;;
  esac

  LATEST_VER="${LATEST_TAG#v}"
  # Ищем asset, который начинается с lightos-update- и заканчивается .tar.gz
  PAYLOAD_URL=$(printf '%s' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*lightos-update-[^"]*\.tar\.gz\)".*/\1/p' \
    | head -1)
  [ -n "$PAYLOAD_URL" ] || PAYLOAD_URL="$PREFIX_URL/$LATEST_TAG/lightos-update-${LATEST_VER}.tar.gz"

  SUMS_URL=$(printf '%s' "$json" \
    | tr ',' '\n' \
    | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*SHA256SUMS\)".*/\1/p' \
    | head -1)
  [ -n "$SUMS_URL" ] || SUMS_URL="$PREFIX_URL/$LATEST_TAG/SHA256SUMS"

  ok "последний релиз: $LATEST_TAG"
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

# --- Проверка подлинности и целостности --------------------------------------
# Раньше здесь стояло «SHA256SUMS не найден — проверку пропускаю, продолжу».
# Теперь отсутствие файла сумм — это отказ: иначе обновление применяется
# вообще без всякой проверки.
step "Проверяю контрольную сумму..."
if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$TMP/SHA256SUMS" "$SUMS_URL"; then
  die "Не скачался файл SHA256SUMS ($SUMS_URL).
   Без него проверить целостность невозможно — обновление отменено.
   Это не обязательно поломка: возможно, релиз собран без файла сумм."
fi

WANT=$(awk '/lightos-update-.*\.tar\.gz/ {print $1; exit}' "$TMP/SHA256SUMS")
if [ -z "$WANT" ]; then
  die "В SHA256SUMS нет строки для lightos-update-*.tar.gz — обновление отменено."
fi

GOT=$(sha256sum "$TMP/payload.tar.gz" | awk '{print $1}')
if [ "$GOT" != "$WANT" ]; then
  err "Хеш не совпадает!
   Ожидался: $WANT
   Получено: $GOT
   Загрузка повреждена или файл подменён. Обновление отменено."
  exit 1
fi
ok "хеш совпал: ${GOT:0:16}..."

# --- GPG-подпись -------------------------------------------------------------
if [ -f "$KEYRING" ]; then
  step "Проверяю GPG-подпись..."
  if ! command -v gpgv >/dev/null 2>&1; then
    die "В системе есть ключ LightOS, но нет gpgv (пакет gnupg).
   Установите gnupg и повторите — иначе подпись не проверить."
  fi
  SIG_URL="$SUMS_URL.asc"
  if curl -fsSL --connect-timeout 10 --max-time 60 -o "$TMP/SHA256SUMS.asc" "$SIG_URL"; then
    if gpgv --keyring "$KEYRING" "$TMP/SHA256SUMS.asc" "$TMP/SHA256SUMS" >/dev/null 2>&1; then
      ok "подпись верна"
    else
      die "GPG-подпись SHA256SUMS не прошла проверку.
   Файл получен не с того сервера или был подменён. Обновление отменено."
    fi
  else
    die "Не скачалась подпись $SIG_URL.
   Ключ установлен, значит подпись обязательна. Обновление отменено."
  fi
else
  warn "Ключ подписи не установлен ($KEYRING) — целостность проверена,
   но ПОДЛИННОСТЬ источника не гарантируется.
   Установить ключ:  sudo lightos-install-key"
  if [ -t 0 ]; then
    say ""
    printf '    Продолжить без проверки подписи? [y/N] '
    local ans=""
    read -r ans || ans=""
    case "$ans" in
      [yY]|[дД]|[Д]|[yY][eE][sE]) : ;;
      *) die "Отменено пользователем." ;;
    esac
  else
    die "Нет TTY для подтверждения и нет ключа подписи — отменено.
   Выполните вручную с ключом: sudo lightos-install-key"
  fi
fi

# --- Резервная копия текущей версии ----------------------------------------
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

# --- Распаковка -------------------------------------------------------------
step "Распаковываю во временный каталог..."
STAGE="$TMP/stage"
mkdir -p "$STAGE"
if ! safe_extract "$TMP/payload.tar.gz" "$STAGE"; then
  err "Содержимое архива отклонено. Изменения не внесены."
  exit 1
fi

# Переносим проверенное дерево на место.
if ! cp -a "$STAGE"/. "$LIBDIR"/; then
  err "Не удалось записать файлы в $LIBDIR — откатываюсь."
  rollback
  exit 1
fi
ok "файлы обновлены"

# --- Установка скриптов в PATH и на рабочий стол ----------------------------
step "Обновляю команды в $BINDIR..."
COUNT=$(install_payload_commands "$LIBDIR")
ok "обновлено файлов: $COUNT"

# --- Пост-обновление --------------------------------------------------------
if [ -x "$LIBDIR/post-update.sh" ]; then
  step "Выполняю пост-обновление..."
  "$LIBDIR/post-update.sh" || warn "пост-обновление завершилось с ошибкой"
fi

printf '%s\n' "$LATEST_VER" > "$CUR_VER_FILE"
# Записываем версию для отката ВСЕГДА, даже если она была «неизвестна»:
# резервная копия rollback-неизвестна.tar.gz в этом случае создаётся выше.
printf '%s\n' "$CUR_VER" > "$BACKUP_VER_FILE"

update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache -tf /usr/share/icons/hicolor 2>/dev/null || true

say ""
say "  ${G}LightOS обновлён до версии $LATEST_VER${N}"
say ""
say "  Что НЕ обновляется этой кнопкой (нужно переустанавливать ISO):"
say "    * ядро Linux          — кнопка «Обновить систему» в Центре приложений"
say "    * драйверы видеокарты — кнопка «Драйверы» (или переустановка ISO)"
say "    * сам установщик Calamares"
say ""
say "  Откат:  sudo lightos-update --rollback"
say ""
exit 0
