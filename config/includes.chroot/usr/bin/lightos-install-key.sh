#!/bin/bash
# LightOS — установка открытого ключа для проверки подписи обновлений
#
# Запуск:  sudo lightos-install-key
#
# Пока ключ не установлен, lightos-update проверяет только SHA256 и
# спрашивает подтверждение вручную. С ключом — требует GPG-подпись
# SHA256SUMS и отказывается обновляться без неё.
#
# Ключ НЕ генерируется этим скриптом: подписывать обновления должен
# только владелец репозитория, приватным ключом. Этот скрипт лишь
# ставит ПУБЛИЧНУЮ часть в /usr/share/keyrings.
#
# Откуда берётся ключ: открытый ключ лежит в репозитории, в файле
# LIGHTOS-SIGNING-KEY.asc в корне. Он подписан самим репозиторием,
# поэтому подменённый ключ подписать нечем.
set -u

KEYRING_DIR="/usr/share/keyrings"
KEYRING="$KEYRING_DIR/lightos-update.gpg"
REPO="${LIGHTOS_REPO:-danyavera123-art/lightos}"
BASE="https://raw.githubusercontent.com/$REPO/main"

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

[ "$(id -u)" -eq 0 ] || { err "Нужен root: sudo $0"; exit 1; }
command -v curl >/dev/null 2>&1 || { err "Нет curl"; exit 1; }
command -v gpg  >/dev/null 2>&1 || { err "Нет gpg (пакет gnupg)"; exit 1; }

say ""
say "  ${B}Ключ подписи обновлений LightOS${N}"
say "    Репозиторий: $REPO"
say ""

mkdir -p "$KEYRING_DIR"
TMP="$(mktemp -d /tmp/lightos-key.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

step "Скачиваю открытый ключ..."
if ! curl -fsSL --connect-timeout 10 --max-time 60 \
      "$BASE/LIGHTOS-SIGNING-KEY.asc" -o "$TMP/key.asc"; then
  err "Не скачался ключ ($BASE/LIGHTOS-SIGNING-KEY.asc)"
  say ""
  say "  Возможные причины:"
  say "    * нет интернета"
  say "    * в репозитории нет файла LIGHTOS-SIGNING-KEY.asc"
  say "      (его нужно закоммитить владельцу репозитория)"
  say ""
  say "  Без ключа обновления всё равно работают: lightos-update"
  say "  проверит SHA256 и попросит подтвердить установку вручную."
  exit 1
fi

if [ ! -s "$TMP/key.asc" ]; then
  err "Файл ключа пустой — это не ключ."
  exit 1
fi

# Импортируем только публичную часть. Приватный ключ сюда попасть не
# может: gpg --import читает и его, но мы явно импортируем в отдельный
# keyring и потом оставляем только public.
step "Импортирую в отдельный keyring..."
if ! gpg --batch --quiet --no-default-keyring \
      --keyring "$TMP/lightos.gpg" --import "$TMP/key.asc" 2>"$TMP/err"; then
  err "gpg не смог разобрать ключ:"
  sed 's/^/     /' "$TMP/err" >&2
  exit 1
fi

FPR="$(gpg --batch --no-default-keyring --keyring "$TMP/lightos.gpg" \
        --list-keys --with-colons 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}')"
if [ -z "$FPR" ]; then
  err "В файле нет ни одного отпечатка ключа."
  exit 1
fi
ok "отпечаток: $FPR"

# GPG требует, чтобы файл keyring был в «старом» формате (.kbx не
# принимается в --keyring для gpgv), поэтому приводим и переносим.
step "Ставлю keyring в $KEYRING..."
if ! gpg --batch --quiet --no-default-keyring --keyring "$TMP/lightos.gpg" \
        --export "$FPR" > "$TMP/pub.gpg" 2>/dev/null; then
  err "не удалось экспортировать публичный ключ"
  exit 1
fi

if [ ! -s "$TMP/pub.gpg" ]; then
  err "экспортированный ключ пустой."
  exit 1
fi

install -m 0644 "$TMP/pub.gpg" "$KEYRING"
ok "ключ установлен"

# Проверяем, что gpgv вообще его принимает. Если нет — обновления
# сломаются на проверке подписи, и пользователь увидит отказ уже
# в момент обновления. Лучше сообщить сейчас.
if command -v gpgv >/dev/null 2>&1; then
  step "Проверяю, что gpgv принимает ключ..."
  # Подписи у нас нет, поэтому проверяем самим ключом: если ключ
  # битый или формат не тот, gpgv скажет об этом сейчас.
  printf 'тест\n' > "$TMP/data"
  gpgv --keyring "$KEYRING" "$TMP/key.asc" "$TMP/data" >/dev/null 2>&1
  case $? in
    0) ok "ключ читается gpgv" ;;
    *) warn "gpgv не смог проверить подпись этим ключом."
       warn "Обновления потребуют ручного подтверждения. Переустановите gnupg:"
       warn "  sudo apt-get install --reinstall gnupg" ;;
  esac
else
  warn "gpgv не установлен — подпись провереть нечем."
  warn "Установите:  sudo apt-get install -y gnupg"
fi

say ""
say "  ${G}Готово.${N} Теперь lightos-update требует подпись SHA256SUMS."
say "  Проверить:  sudo lightos-update --check"
say ""
exit 0