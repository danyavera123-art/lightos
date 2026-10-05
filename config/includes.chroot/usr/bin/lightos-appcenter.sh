#!/bin/bash
# LightOS — Центр приложений
# Установка программ (opencode, Chrome, Discord, VLC...),
# драйверов, обновление системы и обновление самого LightOS.
set -u

# --- Вывод ------------------------------------------------------------------
if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  G=''; Y=''; R=''; N=''
fi

notify() { yad --title="Центр приложений LightOS" --text="$1" --width=460 --center --timeout=8 --timeout-indicator=1 2>/dev/null || true; }
fatal()  { yad --title="Центр приложений LightOS" --text="$1" \
             --width=460 --center --button="OK:0" --image=error 2>/dev/null; exit 1; }

# --- Запуск команды в терминале --------------------------------------------
# Раньше здесь были две почти одинаковые функции run_terminal и
# run_terminal_plain, которые различались только вызовом sudo внутри
# команды. Оставили одну: sudo добавляется в саму команду.
#
# ВАЖНО: временный файл нельзя удалять сразу — терминал стартует не
# мгновенно, и файл исчезал бы до старта bash. Удаляем его изнутри
# скрипта, в самом конце.
run_terminal() {
  local title="$1" cmd="$2"
  local f
  f=$(mktemp /tmp/lightos-cmd.XXXXXX.sh)
  {
    printf '%s\n' '#!/bin/bash'
    printf 'trap '"'"'rm -f "%s"'"'"' EXIT\n' "$f"
    printf '%s\n' "$cmd"
    printf '%s\n' 'echo'
    printf '%s\n' 'echo "Готово. Нажмите Enter для закрытия..."'
    printf '%s\n' 'read -r _'
  } > "$f"
  chmod 0700 "$f"
  if ! xfce4-terminal --title="$title" --maximize --command="bash '$f'" >/dev/null 2>&1 &
  then
    notify "Не удалось открыть терминал."
    rm -f "$f"
    return 1
  fi
  disown 2>/dev/null || true
  return 0
}

# Проверка, что команда есть в PATH (иначе сообщаем об этом в окне, а не
# молча запускаем несуществующий файл).
have() { command -v "$1" >/dev/null 2>&1; }

# Найти LightOS-скрипт: сначала в PATH (как ставит установщик/обновление),
# затем в каталоге библиотеки.
find_lightos() {
  local n="$1" p
  for p in "/usr/local/bin/$n" "/usr/local/lib/lightos/bin/$n.sh"; do
    if [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# --- Установка opencode ----------------------------------------------------
# Раньше здесь был `curl ... | sudo bash` прямо из GUI-процесса: sudo
# запрашивал пароль в терминале, которого у GUI-приложения нет, и
# установка молча падала. Теперь идём в терминал, где пароль спросят.
install_opencode() {
  notify "Открываю терминал для установки opencode.
Введите пароль администратора и дождитесь окончания установки."
  run_terminal "Установка opencode" \
    "curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh && \
     bash /tmp/opencode-install.sh; rc=\$?; rm -f /tmp/opencode-install.sh; \
     if [ \$rc -eq 0 ]; then echo; echo 'opencode установлен. Откройте НОВЫЙ терминал и введите: opencode'; \
     else echo; echo 'Не удалось установить opencode. Проверьте интернет.'; fi"
}

# --- Chrome ----------------------------------------------------------------
install_chrome() {
  notify "Открываю терминал: будет добавлен репозиторий Google
и установлен Google Chrome. Введите пароль администратора."
  run_terminal "Установка Google Chrome" \
    "curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | \
       sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
     echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main' | \
       sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null && \
     sudo apt-get update && sudo apt-get install -y google-chrome-stable"
}

# --- Discord ---------------------------------------------------------------
install_discord() {
  notify "Открываю терминал для загрузки Discord (~120 МБ)."
  run_terminal "Установка Discord" \
    "wget -q --show-progress -O /tmp/discord.deb \
       'https://discord.com/api/download?platform=linux&format=deb' && \
     sudo apt-get update && sudo apt-get install -y /tmp/discord.deb; \
     rm -f /tmp/discord.deb"
}

# --- Steam ----------------------------------------------------------------
# Steam из репозиториев Debian есть только в non-free и только для i386.
# Без подключения i386 установка падала с «Unable to locate package».
install_steam() {
  notify "Открываю терминал для установки Steam.
Steam требует 32-битные библиотеки (i386) — они будут подключены."
  run_terminal "Установка Steam" \
    "sudo dpkg --add-architecture i386 && \
     sudo sed -i 's/^deb \(.*\)$/deb \1/i386/' /etc/apt/sources.list 2>/dev/null; \
     sudo apt-get update && sudo apt-get install -y steam steam-devices"
}

# --- Прочие пакеты --------------------------------------------------------
install_apt() {
  local pkg="$1" name="$2"
  notify "Открываю терминал для установки: $name
Введите пароль администратора."
  run_terminal "Установка $name" \
    "sudo apt-get update && sudo apt-get install -y $pkg"
}

# --- Драйверы -------------------------------------------------------------
# Больше не ставим фиксированный список: lightos-drivers сам определяет
# видеокарту и Wi-Fi-чип. Раньше здесь стоял жёсткий список с
# firmware-brcm80211, который НЕ содержит прошивок для BCM4313 —
# Wi-Fi так и не работал, а Radeon оставался без драйвера.
install_drivers() {
  local p
  if p=$(find_lightos lightos-drivers); then
    notify "Определяю оборудование и ставлю драйверы.
Займёт 2–10 минут. Потребуется пароль администратора."
    run_terminal "Установка драйверов (LightOS)" "sudo '$p'"
  else
    notify "Скрипт lightos-drivers не найден.
Похоже, LightOS установлен не полностью."
  fi
}

# --- Оптимизация ----------------------------------------------------------
# sudo обязателен: настройки CPU-частот, I/O-планировщика и zram меняет
# только root. Раньше здесь был запуск без sudo, и половина настроек
# молча не применялась (плюс скрипт сам себя повторно эскалировал).
run_perf() {
  local p
  if p=$(find_lightos lightos-perf); then
    notify "Применяю оптимизацию. Потребуется пароль администратора."
    run_terminal "Оптимизация LightOS" "sudo '$p'"
  else
    notify "Скрипт lightos-perf не найден."
  fi
}

# --- Обновление LightOS (по кнопке, без флешки) ---------------------------
update_lightos() {
  local p
  if p=$(find_lightos lightos-update); then
    notify "Проверяю обновления LightOS."
    run_terminal "Обновление LightOS" "sudo '$p'"
  else
    notify "Скрипт lightos-update не найден."
  fi
}

# --- Обновление системы (пакеты Debian) -----------------------------------
# autoremove --purge УДАЛЁН намеренно: в LightOS он выносил
# initramfs-tools (он ставился авто-зависимостью live-boot), и система
# переставала загружаться. Чистим только кэш apt.
update_system() {
  notify "Открываю терминал: обновление пакетов Debian.
Введите пароль администратора. Ядро обновится, перезагрузитесь вручную."
  run_terminal "Обновление системы" \
    "sudo apt-get update && sudo apt-get upgrade -y && \
     sudo apt-mark manual initramfs-tools initramfs-tools-core kexec-tools 2>/dev/null; \
     sudo apt-get clean && sudo update-initramfs -u"
}

# --- Диагностика ----------------------------------------------------------
# Без root: --detect ничего не меняет, --status только читает.
diagnostics() {
  local drv perf
  drv=$(find_lightos lightos-drivers || true)
  perf=$(find_lightos lightos-perf || true)
  notify "Собираю отчёт о системе."
  run_terminal "Диагностика LightOS" \
    "${drv:-$(\u0070true)} --detect 2>&1; echo; echo '--- Оптимизация ---'; \
     ${perf:-$(\u0070true)} --status 2>&1; echo; echo '--- Ядро ---'; uname -a"
}

# --- Ключ подписи ---------------------------------------------------------
# Обновления LightOS подписываются GPG. Пока ключ не установлен,
# скрипт обновления лишь предупреждает и просит подтвердить вручную.
install_key() {
  notify "Открываю терминал для установки ключа подписи обновлений."
  run_terminal "Ключ подписи LightOS" "sudo /usr/local/bin/lightos-install-key"
}

# --- Очистка кэша --------------------------------------------------------
clean_cache() {
  notify "Открываю терминал для очистки кэша apt."
  run_terminal "Очистка кэша" \
    "sudo apt-get clean && \
     sudo apt-get autoremove --purge -y && \
     sudo apt-mark manual initramfs-tools initramfs-tools-core kexec-tools 2>/dev/null; \
     sudo update-initramfs -u"
}

# Список программ: ID|Название|Описание
APPS=(
  "opencode|opencode (CLI-ассистент для программирования)|официальный скрипт установки"
  "chrome|Google Chrome (браузер)|из официального репозитория Google"
  "discord|Discord (общение)|официальный .deb пакет"
  "vlc|VLC (видеоплеер)|из репозиториев Debian"
  "telegram|Telegram Desktop|из репозиториев Debian"
  "gimp|GIMP (редактор изображений)|из репозиториев Debian"
  "libreoffice|LibreOffice (офисный пакет)|из репозиториев Debian"
  "steam|Steam (игры)|из репозиториев Debian, потребуется i386"
  "wine|Wine (Windows-программы)|из репозиториев Debian"
)

# Кнопки. Номера соответствуют значениям, которые возвращает yad.
BTN_DRIVERS=1; BTN_PERF=2; BTN_UPD_LIGHTOS=3
BTN_UPD_SYSTEM=4; BTN_DIAG=5; BTN_CACHE=6; BTN_KEY=8; BTN_CLOSE=9

args=(--title="Центр приложений LightOS" --width=740 --height=600 --center
      --list --checklist --separator="|" --print-column=4 --hide-column=4
      --column="Поставить" --column="Программа" --column="Описание" --column="ID"
      --button="Установить выбранное:0"
      --button="Драйверы (GPU / Wi-Fi / звук):$BTN_DRIVERS"
      --button="Оптимизация:$BTN_PERF"
      --button="Обновить LightOS:$BTN_UPD_LIGHTOS"
      --button="Обновить систему (пакеты):$BTN_UPD_SYSTEM"
      --button="Диагностика:$BTN_DIAG"
      --button="Очистить кэш:$BTN_CACHE"
      --button="Ключ подписи обновлений:$BTN_KEY"
      --button="Закрыть:$BTN_CLOSE")

for a in "${APPS[@]}"; do
  IFS="|" read -r id name desc <<< "$a"
  args+=(FALSE "$name" "$desc" "$id")
done

if ! have yad; then
  fatal "Не найден yad — интерфейс Центра приложений.
Установите его командой:  sudo apt-get install -y yad"
fi

choice=$(yad "${args[@]}" 2>/dev/null)
rc=$?

if [ "$rc" -eq "$BTN_CLOSE" ]; then exit 0; fi

case "$rc" in
  "$BTN_DRIVERS")    install_drivers;  exit 0 ;;
  "$BTN_PERF")       run_perf;         exit 0 ;;
  "$BTN_UPD_LIGHTOS") update_lightos; exit 0 ;;
  "$BTN_UPD_SYSTEM") update_system;   exit 0 ;;
  "$BTN_DIAG")       diagnostics;      exit 0 ;;
  "$BTN_CACHE")      clean_cache;      exit 0 ;;
  "$BTN_KEY")        install_key;      exit 0 ;;
  0) : ;;
  *) exit 0 ;;   # yad закрыт крестиком
esac

[ -n "${choice:-}" ] || exit 0

# yad отдаёт ВЫБРАННЫЕ СТРОКИ, разделённые переводом строки, а не "|".
# Раньше строка резалась только по "|", поэтому при выборе нескольких
# программ в цикл попадал один элемент вида "a|b|c" и ничего не ставилось.
while IFS= read -r row; do
  [ -n "$row" ] || continue
  id="${row##*|}"
  id="${id%%$'\t'*}"
  case "$id" in
    opencode)    install_opencode ;;
    chrome)      install_chrome ;;
    discord)     install_discord ;;
    steam)       install_steam ;;
    vlc)         install_apt "vlc" "VLC" ;;
    telegram)    install_apt "telegram-desktop" "Telegram" ;;
    gimp)        install_apt "gimp" "GIMP" ;;
    libreoffice) install_apt "libreoffice" "LibreOffice" ;;
    wine)        install_apt "wine" "Wine" ;;
    *) : ;;
  esac
done <<< "$(printf '%s' "$choice" | tr '\t' '|')"

exit 0