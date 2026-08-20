#!/bin/bash
# LightOS — Центр приложений
# Установка программ (opencode, Chrome, Discord, VLC...) и драйверов

LANG=C

notify() { yad --title="Центр приложений LightOS" --text="$1" --width=420 --center 2>/dev/null; }

# Запуск команды с sudo в отдельном окне терминала (там же просят пароль)
run_terminal() {
  local title="$1" cmd="$2"
  local f
  f=$(mktemp /tmp/lightos-cmd.XXXXXX.sh)
  printf '%s\n' '#!/bin/bash' "$cmd" 'echo' 'echo "Готово. Нажмите Enter для закрытия..."' 'read' > "$f"
  chmod +x "$f"
  xfce4-terminal --title="$title" --maximize --command="bash -c $f" 2>/dev/null
  rm -f "$f"
}

install_opencode() {
  notify "Устанавливаем opencode...
Скачивается официальный скрипт установки.

После установки: перезапусти терминал и введи команду:  opencode"
  curl -fsSL https://opencode.ai/install | bash
  if [ $? -eq 0 ]; then
    notify "opencode установлен!"
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

install_drivers() {
  run_terminal "Установка драйверов" \
    "sudo apt-get update && sudo apt-get install -y firmware-linux firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 xserver-xorg-input-all alsa-utils pulseaudio pavucontrol"
}

update_system() {
  run_terminal "Обновление системы" \
    "sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get autoremove --purge -y"
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

args=(--title="Центр приложений LightOS" --width=680 --height=520 --center
      --list --checklist --separator="|" --print-column=4 --hide-column=4
      --column="Поставить" --column="Программа" --column="Описание" --column="ID"
      --button="Установить выбранное:0"
      --button="Драйверы:1"
      --button="Обновить систему:2"
      --button="Очистить кэш:3"
      --button="Закрыть:4")

for a in "${APPS[@]}"; do
  IFS="|" read -r id name desc <<< "$a"
  args+=(FALSE "$name" "$desc" "$id")
done

choice=$(yad "${args[@]}" 2>/dev/null)
rc=$?

if [ $rc -eq 4 ]; then exit 0; fi

case $rc in
  0) SELECTED="$choice" ;;
  1) install_drivers; exit 0 ;;
  2) update_system; exit 0 ;;
  3) clean_cache; exit 0 ;;
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