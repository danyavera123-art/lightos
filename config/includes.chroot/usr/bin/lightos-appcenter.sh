#!/bin/bash
# LightOS — Центр приложений
# Установка программ (opencode, Chrome, Discord, VLC...),
# драйверов, обновление системы и обновление самого LightOS.

LANG=C

notify() { yad --title="Центр приложений LightOS" --text="$1" --width=420 --center 2>/dev/null; }

# Запуск команды с sudo в отдельном окне терминала (там же просят пароль).
# ВАЖНО: временный файл нельзя удалять сразу — терминал успевает стартовать
# не мгновенно, и файл исчезал бы до старта bash. Удаляем его изнутри
# скрипта, в самом конце.
run_terminal() {
  local title="$1" cmd="$2"
  local f
  f=$(mktemp /tmp/lightos-cmd.XXXXXX.sh)
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' "trap 'rm -f \"$f\"' EXIT"
    printf '%s\n' "$cmd"
    printf '%s\n' 'echo'
    printf '%s\n' 'echo "Готово. Нажмите Enter для закрытия..."'
    printf '%s\n' 'read -r _'
  } > "$f"
  chmod +x "$f"
  xfce4-terminal --title="$title" --maximize --command="bash $f" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# Запуск команды БЕЗ sudo (для скриптов, которые сами не требуют прав)
run_terminal_plain() {
  local title="$1" cmd="$2"
  local f
  f=$(mktemp /tmp/lightos-cmd.XXXXXX.sh)
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' "trap 'rm -f \"$f\"' EXIT"
    printf '%s\n' "$cmd"
    printf '%s\n' 'echo'
    printf '%s\n' 'echo "Готово. Нажмите Enter для закрытия..."'
    printf '%s\n' 'read -r _'
  } > "$f"
  chmod +x "$f"
  xfce4-terminal --title="$title" --maximize --command="bash $f" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

install_opencode() {
  notify "Устанавливаем opencode...
Скачивается официальный скрипт установки.

После установки: перезапусти терминал и введи команду:  opencode"
  # БЫЛО: curl ... | bash  — скрипт ставит opencode в /usr/local/bin,
  # куда обычному пользователю писать нельзя. Теперь через sudo.
  if curl -fsSL https://opencode.ai/install | sudo bash; then
    notify "opencode установлен!

Открой новый терминал и введи:  opencode"
  else
    notify "Не удалось установить opencode. Проверь интернет."
  fi
}

install_chrome() {
  run_terminal "Установка Google Chrome" \
    "curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main' | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null && sudo apt-get update && sudo apt-get install -y google-chrome-stable"
}

install_discord() {
  run_terminal "Установка Discord" \
    "wget -O /tmp/discord.deb 'https://discord.com/api/download?platform=linux&format=deb' && sudo apt-get update && sudo apt-get install -y /tmp/discord.deb && rm -f /tmp/discord.deb"
}

install_apt() {
  run_terminal "Установка $2" \
    "sudo apt-get update && sudo apt-get install -y $1"
}

# --- Драйверы -------------------------------------------------------------
# Больше не ставим фиксированный список: lightos-drivers.sh сам определяет
# видеокарту и Wi-Fi-чип. Раньше здесь стоял жёсткий список с
# firmware-brcm80211, который НЕ содержит прошивок для BCM4313 —
# Wi-Fi так и не работал, а Radeon оставался без драйвера.
install_drivers() {
  if [ ! -x /usr/local/bin/lightos-drivers ]; then
    run_terminal "Установка драйверов" \
      "sudo /usr/local/lib/lightos/bin/lightos-drivers.sh"
    return
  fi
  run_terminal "Установка драйверов (LightOS)" \
    "sudo /usr/local/bin/lightos-drivers"
}

# --- Оптимизация ----------------------------------------------------------
run_perf() {
  run_terminal_plain "Оптимизация LightOS" "/usr/local/bin/lightos-perf"
}

# --- Обновление LightOS (по кнопке, без флешки) ---------------------------
update_lightos() {
  run_terminal "Обновление LightOS" \
    "sudo /usr/local/bin/lightos-update"
}

# --- Обновление системы (пакеты Debian) -----------------------------------
update_system() {
  run_terminal "Обновление системы" \
    "sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get autoremove --purge -y"
}

# --- Диагностика ----------------------------------------------------------
diagnostics() {
  run_terminal_plain "Диагностика LightOS" \
    "/usr/local/bin/lightos-drivers --detect; echo; /usr/local/bin/lightos-perf --status"
}

clean_cache() {
  run_terminal "Очистка кэша" \
    "sudo apt-get clean && sudo apt-get autoremove --purge -y"
}

# Список программ: ID|Название|Описание
APPS=(
  "opencode|opencode (CLI-ассистент для программирования)|ставится официальным скриптом"
  "chrome|Google Chrome (браузер)|ставится из официального репозитория"
  "discord|Discord (общение)|официальный .deb пакет"
  "vlc|VLC (видеоплеер)|из репозиториев Debian"
  "telegram|Telegram Desktop|из репозиториев Debian"
  "gimp|GIMP (редактор изображений)|из репозиториев Debian"
  "libreoffice|LibreOffice (офисный пакет)|из репозиториев Debian"
  "steam|Steam (игры)|из репозиториев Debian"
  "wine|Wine (Windows-программы)|из репозиториев Debian"
)

args=(--title="Центр приложений LightOS" --width=720 --height=560 --center
      --list --checklist --separator="|" --print-column=4 --hide-column=4
      --column="Поставить" --column="Программа" --column="Описание" --column="ID"
      --button="Установить выбранное:0"
      --button="Драйверы (GPU / Wi-Fi / звук):1"
      --button="Оптимизация:2"
      --button="Обновить LightOS:3"
      --button="Обновить систему (пакеты):4"
      --button="Диагностика:5"
      --button="Очистить кэш:6"
      --button="Закрыть:7")

for a in "${APPS[@]}"; do
  IFS="|" read -r id name desc <<< "$a"
  args+=(FALSE "$name" "$desc" "$id")
done

choice=$(yad "${args[@]}" 2>/dev/null)
rc=$?

if [ $rc -eq 7 ]; then exit 0; fi

case $rc in
  0) SELECTED="$choice" ;;
  1) install_drivers; exit 0 ;;
  2) run_perf; exit 0 ;;
  3) update_lightos; exit 0 ;;
  4) update_system; exit 0 ;;
  5) diagnostics; exit 0 ;;
  6) clean_cache; exit 0 ;;
  *) exit 0 ;;
esac

[ -z "$SELECTED" ] && exit 0

IFS="|" read -ra selected_ids <<< "$SELECTED"
for id in "${selected_ids[@]}"; do
  case "$id" in
    opencode)    install_opencode ;;
    chrome)      install_chrome ;;
    discord)     install_discord ;;
    vlc)         install_apt "vlc" "VLC" ;;
    telegram)    install_apt "telegram-desktop" "Telegram" ;;
    gimp)        install_apt "gimp" "GIMP" ;;
    libreoffice) install_apt "libreoffice" "LibreOffice" ;;
    steam)       install_apt "steam" "Steam" ;;
    wine)        install_apt "wine" "Wine" ;;
  esac
done

exit 0