#!/bin/bash
# LightOS — поиск и установка драйверов
#
# Запуск:  sudo lightos-drivers.sh            (интерактивно, с отчётом)
#         lightos-drivers.sh --detect         (только отчёт, без правок)
#
# Скрипт сам определяет видеокарту и Wi-Fi-чип и ставит то, что нужно.
# Ручной выбор драйвера — главная причина «система тормозит»: Mesa
# без правильного DRM-модуля рисует через llvmpipe или вообще через
# встроенную Intel-графику, даже если дискретная карта поддерживается.
set -u

DETECT_ONLY=0
[ "${1:-}" = "--detect" ] && DETECT_ONLY=1

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
err()  { printf '   %s[XX]%s %s\n' "$R" "$N" "$*"; }

[ "$(id -u)" -eq 0 ] || { err "Нужен root: sudo $0"; exit 1; }
command -v lspci >/dev/null || { step "Ставлю pciutils (нужен для определения железа)"; apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y pciutils; }

# --- что ставить ------------------------------------------------------------
PKGS=()
GPU_NOTE=""
WIFI_NOTE=""

detect_gpu() {
  # ВАЖНО: у lspci -nn идентификатор [vvvv:dddd] печатается ТОЛЬКО для
  # неопознанных устройств. Для Intel 945GM его не будет — и разбор по
  # lspci не находит вендора. Поэтому берём ID напрямую из sysfs,
  # где vendor/device есть всегда.
  #
  # Видеокарт может быть несколько (встроенная Intel + дискретная AMD).
  # Ставим драйверы ДЛЯ ВСЕХ — Xorg сам выберет нужный, а лишний пакет
  # не мешает. Отдельно считаем, какая будет использоваться как основная.
  local slots found=0 note="" main="" mainprio=-1
  slots=$(lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' \
            | grep -v -Ei 'audio|multimedia' | cut -d' ' -f1 | tr 'A-F' 'a-f')

  [ -n "$slots" ] || { GPU_NOTE="Видеокарта не найдена"; return; }

  # Читаем ID из sysfs — там vendor/device есть всегда, в отличие от lspci -nn,
  # который печатает [vvvv:dddd] только для неопознанных устройств.
  local slot sys vendor dev name prio
  for slot in $slots; do
    sys="/sys/bus/pci/devices/0000:$slot"
    [ -r "$sys/vendor" ] || sys="/sys/bus/pci/devices/$slot"
    [ -r "$sys/vendor" ] || continue
    vendor=$(tr -d '[:space:]' < "$sys/vendor" | sed 's/^0x//; s/^0X//')
    dev=$(tr -d '[:space:]' < "$sys/device" 2>/dev/null | sed 's/^0x//; s/^0X//')
    [ -n "$vendor" ] && [ -n "$dev" ] || continue
    found=1
    # Имя берём из САМОЙ строки lspci этого слота (не отдельным вызовом lspci -s,
    # который печатает весь список и подмешивал чужие устройства в отчёт)
    # Формат lspci: "00:02.0 VGA compatible controller: ..." —
    # после слота ПРОБЕЛ, а не двоеточие.
    name=$(lspci 2>/dev/null | sed -n "s/^${slot} *//p" | cut -c1-58)
    note="${note}${note:+
  }$slot  ${vendor}:${dev}  ${name:-(название не прочитано)}"

    # Приоритет: чем выше, тем вероятнее это основная карта.
    case "$vendor" in
      8086) prio=1 ;;   # Intel — почти всегда встроенная, рисуетCompositor
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
        PKGS+=(xserver-xorg-video-nouveau firmware-nonfree)
        note="${note}
      -> nouveau. Для игр лучше nvidia-driver — но нужен перезапуск
         и выбор драйвера в lightdm (nvidia-settings от root)"
        ;;
      1a03)
        PKGS+=(xserver-xorg-video-ati firmware-amd-graphics)
        note="${note}
      -> ati/radeon"
        ;;
      1102|10b8|100c)
        PKGS+=(xserver-xorg-video-fbdev)
        ;;
      *)
        ;;
    esac

    if [ "$prio" -gt "$mainprio" ]; then
      mainprio=$prio; main="$vendor:$dev"
    fi
  done

  [ "$found" -eq 1 ] || { GPU_NOTE="Не удалось прочитать PCI-идентификаторы видеокарты"; return; }

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
  devs=$(lspci -nn | grep -Ei 'network controller' | head -5)
  [ -n "$devs" ] || { WIFI_NOTE="Wi-Fi адаптера нет"; return; }
  names=$(echo "$devs" | grep -oP '(?<=: ).*' | cut -c1-60)

  # Broadcom: часть чипов (BCM4313/4321/4322/4325) НЕ поддерживается
  # открытым b43 — в таблице b43_bcma_tbl нет core id 0x13. Их ведёт
  # только проприетарный broadcom-sta (модуль wl).
  if echo "$devs" | grep -qiE 'Broadcom.*(14e4:(4727|4728|4313|4312|4322|4325)|BCM43(13|22|25|27))'; then
    PKGS+=(dkms broadcom-sta-dkms linux-headers-amd64 wireless-regdb iw)
    WIFI_NOTE="Broadcom — открытый b43 эти чипы не тянет, ставлю
   проприетарный broadcom-sta (модуль wl). Нужны kernel headers."
    # b43/bcma мешают wl
    mkdir -p /etc/modprobe.d 2>/dev/null || true
    printf 'blacklist b43\nblacklist b43legacy\nblacklist bcma\nblacklist bcma-hci\n' \
      > /etc/modprobe.d/blacklist-broadcom-sta.conf 2>/dev/null \
      || warn "не смог записать blacklist для broadcom-sta"
    return
  fi

  # Остальные Broadcom — открытый b43 + firmware-brcm80211
  if echo "$devs" | grep -qi broadcom; then
    PKGS+=(firmware-brcm80211 broadcom-sta-dkms dkms linux-headers-amd64 iw)
    WIFI_NOTE="Broadcom — ставлю и firmware-brcm80211, и broadcom-sta."
    return
  fi

  case "$devs" in
    *Realtek*)
      PKGS+=(firmware-realtek iw rfkill)
      # 8812au/rtl8821cu требуют DKMS — сторонних, в Debian их нет,
      # поэтому для них нужен бэкпорт kernel из репозитория пользователя.
      echo "$devs" | grep -qiE '8812|8821|rtl88' && \
        WIFI_NOTE="$names

   ВНИМАНИЕ: Realtek 88xx. В Debian нет DKMS-модуля для этого чипа.
   Для него нужен сторонний бэкпорт ядра (linux-image-*-rt из репозитория
   mxlinux/kali) либо rtl8821ce. Пока работает встроенный драйвер rtl8xxxu."
      ;;
    *Intel*)   PKGS+=(firmware-iwlwifi iw rfkill) ;;
    *Atheros*) PKGS+=(firmware-atheros iw rfkill) ;;
    *MediaTek*|*Ralink*) PKGS+=(firmware-raltek iw rfkill) ;;
    *Qualcomm*) PKGS+=(firmware-iwlwifi iw rfkill) ;;
    *)
      PKGS+=(firmware-linux iw rfkill)
      WIFI_NOTE="Неизвестный вендор — ставлю firmware-linux целиком."
      ;;
  esac
}

detect_audio() {
  local dev
  dev=$(lspci -nn | grep -Ei 'audio device' | head -1)
  [ -z "$dev" ] && return
  case "$dev" in
    *Realtek*) PKGS+=(firmware-sof-signed alsa-utils) ;;
    *Intel*)   PKGS+=(firmware-sof-signed alsa-utils) ;;
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

if [ "$DETECT_ONLY" -eq 1 ]; then exit 0; fi

step "Обновляю список пакетов..."
apt-get update -qq || warn "apt-get update завершился с ошибкой — возможно, нет интернета"

step "Устанавливаю драйверы (это займёт 2-10 минут)..."
if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"; then
  ok "пакеты установлены"
else
  err "часть пакетов не установилась (список выше покажет, что именно)"
  apt-get install -y "${PKGS[@]}" 2>&1 | tail -20
fi

# --- DKMS: собрать модули под текущее ядро ---------------------------------
if dpkg -l broadcom-sta-dkms 2>/dev/null | grep -q '^ii'; then
  step "Собираю модули DKMS под ядро $(uname -r)..."
  if dkms autoinstall 2>&1 | tail -5; then
    ok "модули собраны"
  else
    err "dkms autoinstall не удался — нужен пакет linux-headers-$(uname -r)"
  fi
  update-initramfs -u 2>/dev/null && ok "initramfs пересобран"
fi

# --- Проверка результата ---------------------------------------------------
say ""
step "Проверяю, привязался ли драйвер видеокарты..."

if command -v glxinfo >/dev/null; then
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

if command -v lsmod >/dev/null; then
  lsmod 2>/dev/null | grep -qw wl && ok "модуль broadcom-sta (wl) загружен" || true
  # Проверяем именно Broadcom-адаптеры: если они есть, модуль wl обязан быть
  local has_broadcom=0
  lspci 2>/dev/null | grep -qi broadcom && has_broadcom=1
  if [ "$has_broadcom" -eq 1 ]; then
    if lspci -k 2>/dev/null | grep -A3 'Network controller' \
         | grep -q 'Kernel driver in use: wl'; then
      ok "Wi-Fi на Broadcom работает через модуль wl"
    else
      warn "Broadcom: модуль wl ещё не загружен — нужна перезагрузка.
   Проверить после перезагрузки:  sudo modprobe wl && dmesg | grep -i wl"
    fi
  fi
fi

say ""
say "  ${B}Готово.${N} ${Y}Перезагрузитесь${N}, чтобы драйверы заработали:"
say "    sudo reboot"
say ""
exit 0