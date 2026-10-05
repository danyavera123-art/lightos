#!/bin/bash
# LightOS — поиск и установка драйверов
#
# Запуск:  sudo lightos-drivers            интерактивно, с отчётом
#         lightos-drivers --detect         ТОЛЬКО отчёт: ничего не ставит
#                                           и НЕ меняет /etc/modprobe.d
#         sudo lightos-drivers --nvidia    добавить проприетарный драйвер NVIDIA
#         sudo lightos-drivers --revert-broadcom   вернуть открытый b43
#
# Скрипт сам определяет видеокарту и Wi-Fi-чип и ставит то, что нужно.
# Ручной выбор драйвера — главная причина «система тормозит»: Mesa
# без правильного DRM-модуля рисует через llvmpipe или вообще через
# встроенную Intel-графику, даже если дискретная карта поддерживается.
set -u
set -o pipefail

DETECT_ONLY=0
NVIDIA_PROPRIETARY=0
REVERT_BROADCOM=0
for a in "$@"; do
  case "$a" in
    --detect)          DETECT_ONLY=1 ;;
    --nvidia)          NVIDIA_PROPRIETARY=1 ;;
    --revert-broadcom) REVERT_BROADCOM=1 ;;
    -h|--help)
      printf '%s\n' "Использование:"
      printf '%s\n' "  sudo lightos-drivers              определить и поставить драйверы"
      printf '%s\n' "  lightos-drivers --detect          только отчёт, ничего не менять"
      printf '%s\n' "  sudo lightos-drivers --nvidia     поставить проприетарный NVIDIA"
      printf '%s\n' "  sudo lightos-drivers --revert-broadcom   вернуть открытый b43"
      exit 0 ;;
    *) printf 'Неизвестный аргумент: %s (см. --help)\n' "$a" >&2; exit 1 ;;
  esac
done

# --- вывод -----------------------------------------------------------------
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

# Режим --detect НЕ требует root: он ничего не меняет.
# Раньше root требовался всегда, хотя скрипт к тому моменту уже успевал
# поставить pciutils и записать /etc/modprobe.d/blacklist-broadcom-sta.conf —
# то есть «отчёт без установки» менял систему.
if [ "$DETECT_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  err "Нужен root: sudo $0"
  exit 1
fi

# pciutils нужен для определения железа. В --detect мы его НЕ ставим:
# предупреждаем и выходим, чтобы отчёт оставался безопасным.
if ! command -v lspci >/dev/null 2>&1; then
  if [ "$DETECT_ONLY" -eq 1 ]; then
    warn "lspci (пакет pciutils) не установлен — определить железо нечем."
    warn "Поставить:  sudo apt-get install -y pciutils"
    exit 1
  fi
  step "Ставлю pciutils (нужен для определения железа)"
  apt-get update -qq || warn "apt-get update не отработал — возможно, нет интернета"
  DEBIAN_FRONTEND=noninteractive apt-get install -y pciutils \
    || { err "не поставился pciutils"; exit 1; }
fi

# --- что ставить ------------------------------------------------------------
PKGS=()
GPU_NOTE=""
WIFI_NOTE=""
GPU_MAIN=""
KVER="$(uname -r)"
# broadcom-sta нужен ТОЛЬКО для чипов, которые открытый b43 не тянет.
NEED_BROADCOM_STA=0
BLACKLIST_BROADCOM=0

detect_gpu() {
  # У lspci -nn идентификатор [vvvv:dddd] печатается ТОЛЬКО для
  # неопознанных устройств. Для Intel 945GM его не будет. Поэтому ID
  # читаем из sysfs, где vendor/device есть всегда.
  local slots found=0 note="" main="" mainprio=-1
  slots=$(lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' \
            | grep -v -Ei 'audio|multimedia' | cut -d' ' -f1 | tr 'A-F' 'a-f')

  [ -n "$slots" ] || { GPU_NOTE="Видеокарта не найдена"; return 0; }

  local slot sys vendor dev name prio
  for slot in $slots; do
    sys="/sys/bus/pci/devices/0000:$slot"
    [ -r "$sys/vendor" ] || sys="/sys/bus/pci/devices/$slot"
    [ -r "$sys/vendor" ] || continue
    vendor=$(tr -d '[:space:]' < "$sys/vendor" | sed 's/^0x//; s/^0X//')
    dev=$(tr -d '[:space:]' < "$sys/device" 2>/dev/null | sed 's/^0x//; s/^0X//')
    [ -n "$vendor" ] && [ -n "$dev" ] || continue
    found=1
    # Имя берём из САМОЙ строки lspci этого слота (отдельный lspci -s
    # печатает весь список и подмешивал чужие устройства в отчёт).
    name=$(lspci 2>/dev/null | sed -n "s/^${slot} *//p" | cut -c1-58)
    note="${note}${note:+
  }$slot  ${vendor}:${dev}  ${name:-(название не прочитано)}"

    case "$vendor" in
      8086) prio=1 ;;   # Intel — почти всегда встроенная, рисует композитор
      1002|1a03) prio=3 ;;  # AMD/ATI — дискретная
      10de) prio=3 ;;   # NVIDIA
      1102|10b8|100c) prio=2 ;; # VIA/ULSI/3dfx
      *) prio=1 ;;
    esac

    case "$vendor" in
      1002)  # AMD/ATI
        case "$dev" in
          68e0|68e1|6640|6641|6642|6710|6711|68a0|68a1|6900|6901|6918|6919|6920|6921)
            # Cedar, Park, Hemlock, Cypress — это rebadge Cedar.
            # amdgpu ищет прошивку PITCAIRN/PALADIN, которой для них нет,
            # поэтому карта молча остаётся без драйвера.
            PKGS+=(xserver-xorg-video-radeon firmware-amd-graphics)
            note="${note}
      -> radeon + firmware-amd-graphics (amdgpu НЕ подходит: нет прошивки)"
            ;;
          *)
            PKGS+=(xserver-xorg-video-amdgpu firmware-amd-graphics)
            note="${note}
      -> amdgpu + firmware-amd-graphics"
            ;;
        esac
        ;;
      8086)
        PKGS+=(xserver-xorg-video-intel intel-microcode)
        note="${note}
      -> intel (встроенная графика, через неё идёт вывод на экран)"
        ;;
      10de)
        if [ "$NVIDIA_PROPRIETARY" -eq 1 ]; then
          # non-free включён в build.sh (--archive-areas), nvidia-driver
          # оттуда и ставится. Драйвер требует перезагрузки.
          PKGS+=(nvidia-driver nvidia-settings)
          note="${note}
      -> nvidia-driver (проприетарный, non-free)"
        else
          # firmware-nonfree в bookworm не существует: с 2019 прошивки
          # nouveau живут в самом драйвере.
          PKGS+=(xserver-xorg-video-nouveau)
          note="${note}
      -> nouveau. Проприетарный драйвер: sudo lightos-drivers --nvidia"
        fi
        ;;
      1a03)
        PKGS+=(xserver-xorg-video-ati firmware-amd-graphics)
        note="${note}
      -> ati/radeon"
        ;;
      1102|10b8|100c)
        PKGS+=(xserver-xorg-video-fbdev)
        ;;
    esac

    if [ "$prio" -gt "$mainprio" ]; then
      mainprio=$prio; main="$vendor:$dev"
    fi
  done

  [ "$found" -eq 1 ] || { GPU_NOTE="Не удалось прочитать PCI-идентификаторы видеокарты"; return 0; }

  GPU_MAIN="$main"
  if [ "$mainprio" -ge 3 ]; then
    GPU_NOTE="$note

  Основной драйвер будет для $main (дискретная карта).
  Если после установки glxinfo покажет Intel — значит Xorg не подхватил
  дискретную карту; проверьте:  lspci -k | grep -A3 VGA"
  else
    GPU_NOTE="$note

  Основной драйвер будет для $main (встроенная графика).
  Дискретной карты нет или она не определяется."
  fi
}

detect_wifi() {
  local devs names
  devs=$(lspci -nn 2>/dev/null | grep -Ei 'network controller' | head -5)
  [ -n "$devs" ] || { WIFI_NOTE="Wi-Fi адаптера нет"; return 0; }
  names=$(printf '%s' "$devs" | sed -n 's/^[^:]*: *//p' | cut -c1-60)

  # Broadcom: часть чипов (BCM4313/4321/4322/4325) НЕ поддерживается
  # открытым b43 — в таблице b43_bcma_tbl нет core id 0x13. Их ведёт
  # только проприетарный broadcom-sta (модуль wl).
  if printf '%s' "$devs" | grep -qiE 'Broadcom.*(14e4:(4727|4728|4313|4312|4322|4325)|BCM43(13|22|25|27))'; then
    NEED_BROADCOM_STA=1
    BLACKLIST_BROADCOM=1
    WIFI_NOTE="Broadcom — открытый b43 эти чипы не тянет.
   Ставлю проприетарный broadcom-sta (модуль wl) и заголовки ядра $KVER."
  elif printf '%s' "$devs" | grep -qi broadcom; then
    # Остальные Broadcom: открытый b43 + firmware-brcm80211.
    # ВАЖНО: broadcom-sta здесь НЕ ставится, и b43 НЕ блокируется.
    NEED_BROADCOM_STA=0
    BLACKLIST_BROADCOM=0
    WIFI_NOTE="Broadcom — ставлю открытый b43 + firmware-brcm80211.
   Открытый драйвер надёжнее и не требует DKMS."
  else
    case "$devs" in
      *Realtek*)
        PKGS+=(firmware-realtek iw rfkill)
        printf '%s' "$devs" | grep -qiE '8812|8821|rtl88' && \
          WIFI_NOTE="$names

   ВНИМАНИЕ: Realtek 88xx. В Debian нет DKMS-модуля для этого чипа.
   Нужен сторонний бэкпорт ядра либо rtl8821ce. Пока работает rtl8xxxu."
        ;;
      *Intel*)   PKGS+=(firmware-iwlwifi iw rfkill) ;;
      *Atheros*) PKGS+=(firmware-atheros iw rfkill) ;;
      *MediaTek*|*Ralink*) PKGS+=(firmware-realtek iw rfkill) ;;
      *Qualcomm*) PKGS+=(firmware-iwlwifi iw rfkill) ;;
      *)
        PKGS+=(firmware-linux iw rfkill)
        WIFI_NOTE="Неизвестный вендор — ставлю firmware-linux целиком."
        ;;
    esac
    return 0
  fi

  if [ "$NEED_BROADCOM_STA" -eq 1 ]; then
    PKGS+=(dkms broadcom-sta-dkms "linux-headers-$KVER" wireless-regdb iw)
  else
    PKGS+=(firmware-brcm80211 iw rfkill)
  fi
}

detect_audio() {
  local dev
  dev=$(lspci -nn 2>/dev/null | grep -Ei 'audio device' | head -1)
  [ -n "$dev" ] || return 0
  case "$dev" in
    *Realtek*) PKGS+=(alsa-utils) ;;
    *Intel*)   PKGS+=(alsa-utils firmware-sof-signed) ;;
    *VIA*|*Broadcom*) PKGS+=(alsa-utils) ;;
  esac
}

step "Определяю оборудование..."
detect_gpu
detect_wifi
detect_audio

# Базовые пакеты: без них ни драйвер, ни glxinfo не работают
PKGS+=(mesa-utils pciutils usbutils rfkill)

# Убираем дубли, сохраняя порядок
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | awk 'NF && !seen[$0]++')

say ""
say "  ${B}Видеокарта${N}"
say "${GPU_NOTE}"
say ""
say "  ${B}Wi-Fi${N}"
say "    ${WIFI_NOTE}"
say ""
say "  ${B}Будет установлено:${N} ${#PKGS[@]} пакет(ов)"
for p in "${PKGS[@]}"; do say "    - $p"; done
say ""

# --- Точка выхода для отчёта -------------------------------------------------
# Здесь, а не в начале: определение состояло только из чтения sysfs/lspci.
# Всё, что меняет систему (apt-get, запись в /etc/modprobe.d), идёт ниже.
if [ "$DETECT_ONLY" -eq 1 ]; then
  say "  ${G}Это был только отчёт — ничего не установлено и не изменено.${N}"
  exit 0
fi

# --- Возврат к открытому Broadcom ---------------------------------------------
if [ "$REVERT_BROADCOM" -eq 1 ]; then
  step "Возвращаю открытый драйвер Broadcom (b43)..."
  rm -f /etc/modprobe.d/blacklist-broadcom-sta.conf
  apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y firmware-brcm80211 iw rfkill \
    || warn "не удалось поставить firmware-brcm80211"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y broadcom-sta-dkms || warn "broadcom-sta-dkms не удалён"
  ok "b43 разблокирован. Перезагрузитесь: sudo reboot"
  exit 0
fi

# --- Blacklist Broadcom ------------------------------------------------------
# Пишется ТОЛЬКО здесь и ТОЛЬКО когда broadcom-sta действительно нужен.
# В образе этот файл больше не создаётся (раньше он ломал Wi-Fi на чипах,
# где b43 работает отлично, а wl часто вообще не собирается).
apply_blacklist() {
  local mode="$1"
  mkdir -p /etc/modprobe.d 2>/dev/null || true
  case "$mode" in
    block)
      printf '# Нужно для Broadcom BCM4313/4321/4322/4325: открытый b43 их не\n# поддерживает (нет core id 0x13 в b43_bcma_tbl).\n# Вернуть b43:  sudo lightos-drivers --revert-broadcom\nblacklist b43\nblacklist b43legacy\nblacklist bcma\nblacklist bcma-hci\n' \
        > /etc/modprobe.d/blacklist-broadcom-sta.conf 2>/dev/null \
        || warn "не смог записать blacklist для broadcom-sta"
      ;;
    unblock)
      rm -f /etc/modprobe.d/blacklist-broadcom-sta.conf
      ;;
  esac
}

step "Обновляю список пакетов..."
apt-get update -qq || warn "apt-get update завершился с ошибкой — возможно, нет интернета"

step "Устанавливаю драйверы (это займёт 2-10 минут)..."
INSTALL_RC=0
if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"; then
  ok "пакеты установлены"
else
  warn "часть пакетов не установилась — ставлю без --no-install-recommends"
  if apt-get install -y "${PKGS[@]}"; then
    INSTALL_RC=0
  else
    INSTALL_RC=1
    err "часть пакетов не установилась (список выше покажет, что именно)"
  fi
fi

# --- DKMS: собрать модули под текущее ядро ----------------------------------
DKMS_OK=1
if [ "$NEED_BROADCOM_STA" -eq 1 ]; then
  if dpkg -l broadcom-sta-dkms 2>/dev/null | grep -q '^ii'; then
    step "Собираю модули DKMS под ядро $KVER..."
    if command -v dkms >/dev/null 2>&1; then
      if dkms autoinstall 2>&1 | tail -5; then
        ok "модули собраны"
      else
        DKMS_OK=0
        err "dkms autoinstall не удался — нужен пакет linux-headers-$KVER"
      fi
    else
      DKMS_OK=0
    fi
  else
    DKMS_OK=0
    warn "broadcom-sta-dkms не установлен — Wi-Fi на этом чипе не заработает"
  fi

  # Ключевое исправление: если wl не собрался, блокировка b43 снимается.
  # Иначе на чипе, которому нужен broadcom-sta, пользователь получает
  # НИ ОДНОГО работающего драйвера — хуже, чем до установки.
  if [ "$DKMS_OK" -eq 1 ]; then
    step "Блокирую b43/bcma (мешают модулю wl)..."
    apply_blacklist block
    update-initramfs -u >/dev/null 2>&1 && ok "initramfs пересобран" \
      || warn "initramfs не пересобран — перезагрузитесь вручную"
  else
    warn "broadcom-sta не собрался — СНИМАЮ блокировку b43, чтобы Wi-Fi работал"
    apply_blacklist unblock
    apt-get install -y --no-install-recommends firmware-brcm80211 iw rfkill >/dev/null 2>&1 \
      || warn "не удалось поставить firmware-brcm80211"
  fi
else
  # Открытый Broadcom: убеждаемся, что b43 НЕ заблокирован.
  if [ -f /etc/modprobe.d/blacklist-broadcom-sta.conf ]; then
    warn "найден blacklist Broadcom, а этому чипу b43 подходит — снимаю"
    apply_blacklist unblock
    apt-get install -y --no-install-recommends firmware-brcm80211 >/dev/null 2>&1 || true
    update-initramfs -u >/dev/null 2>&1 || true
  fi
fi

# --- Проверка результата -----------------------------------------------------
say ""
step "Проверяю, привязался ли драйвер видеокарты..."

if command -v glxinfo >/dev/null 2>&1; then
  RENDERER=$(glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p')
  GLVER=$(glxinfo -B 2>/dev/null | sed -n 's/^OpenGL version string: //p' | cut -d, -f1)
  if [ -n "$RENDERER" ]; then
    say "    Рендерер: $RENDERER"
    say "    OpenGL:   ${GLVER:-?}"
    case "$RENDERER" in
      *llvmpipe*|*swrast*)
        warn "Включён ПРОГРАММНЫЙ рендеринг (llvmpipe).
   Видеокарта не используется — игры будут очень медленными.
   Перезагрузитесь и проверьте: lspci -k | grep -A2 'VGA compatible'" ;;
      *"Intel(R) HD"*)
        warn "Рисует встроенная Intel-графика. Если у ноутбука есть
   дискретная AMD-карта — она не используется. Это лечится
   драйвером radeon (см. выше) и перезагрузкой." ;;
      *) ok "аппаратное ускорение работает" ;;
    esac
  else
    warn "glxinfo не смог определить рендерер"
  fi
fi

if command -v lsmod >/dev/null 2>&1; then
  lsmod 2>/dev/null | grep -qw wl && ok "модуль broadcom-sta (wl) загружен"
  if lspci -k 2>/dev/null | grep -A3 'Network controller' \
       | grep -q 'Kernel driver in use: wl'; then
    ok "Wi-Fi на Broadcom работает через модуль wl"
  elif [ "$NEED_BROADCOM_STA" -eq 1 ]; then
    warn "Broadcom: модуль wl ещё не загружен — нужна перезагрузка.
   Проверить после перезагрузки:  sudo modprobe wl && dmesg | grep -i wl"
  fi
fi

say ""
if [ "$INSTALL_RC" -ne 0 ]; then
  say "  ${Y}Готово с ошибками${N} — часть пакетов не поставилась (список выше)."
else
  say "  ${G}Готово.${N} ${Y}Перезагрузитесь${N}, чтобы драйверы заработали:"
fi
say "    sudo reboot"
say ""
[ "$INSTALL_RC" -eq 0 ] || exit 1
exit 0
