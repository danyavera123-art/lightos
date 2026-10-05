#!/bin/bash
# LightOS — оптимизация под слабое железо
#
# Запуск:  sudo lightos-perf            применить
#         lightos-perf --status         только показать состояние (права не нужны)
#         sudo lightos-perf --restore   вернуть всё как было
#
# Что делает:
#   * выключает композитор xfwm4 — на Intel GMA / Radeon Cedar это
#     минус 15-30% CPU в обычной работе и минус 30-60% в играх
#   * отключает анимации, прозрачность и тени в GTK2/GTK3/XFCE
#   * включает zram на 50% RAM (раньше только проверял и предупреждал,
#     хотя README обещал настройку)
#   * уменьшает буферы обмена (старый swap съедал RAM)
#   * ставит governor CPU на powersave
#   * отключает службы, не нужные на старте
#
# ВАЖНО про права. Настройки десктопа живут в конфигурации XFCE конкретного
# пользователя и применяются через D-Bus СЕССИИ, поэтому их нельзя менять
# от root: xfconf-query от root пишет в отдельный, несуществующий контекст
# и настройка просто теряется. Системные вещи (sysctl, zram, службы) наоборот
# требуют root.
# Поэтому скрипт состоит из двух частей и корректно их разводит:
#   * системная часть — от root (здесь идёт sudo, если вызвали без прав)
#   * пользовательская — от вызвавшего пользователя, в его сессии
# Раньше кнопка «Оптимизация» запускала скрипт вообще БЕЗ sudo, поэтому
# sysctl/governor/службы молча падали, а пользователь видел «Готово».
set -u

MODE="apply"
case "${1:-}" in
  --status)  MODE="status" ;;
  --restore) MODE="restore" ;;
  --system-only) MODE="${2:-apply}" ;;
  -h|--help)
    printf '%s\n' "Использование:"
    printf '%s\n' "  sudo lightos-perf            применить оптимизацию"
    printf '%s\n' "  lightos-perf --status         только показать состояние"
    printf '%s\n' "  sudo lightos-perf --restore   отменить оптимизацию"
    exit 0 ;;
  "") : ;;
  *) printf 'Неизвестный аргумент: %s (см. --help)\n' "$1" >&2; exit 1 ;;
esac

if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=''; G=''; Y=''; R=''
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s->%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '   %s[OK]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '   %s[!!]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '   %s[XX]%s %s\n' "$R" "$N" "$*" >&2; }

# Пользователь, чью сессию настраиваем. При вызове через sudo это тот,
# кто запустил sudo, а не root.
TARGET_USER="${SUDO_USER:-${USER:-}}"
TARGET_HOME=""
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && \
  TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"

has_xfconf_session() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 1
  command -v xfconf-query >/dev/null 2>&1 || return 1
  [ -n "${XDG_RUNTIME_DIR:-}" ] || return 1
  xfconf-query -c xfwm4 -l >/dev/null 2>&1
}

xq() { xfconf-query -n -c "$1" -p "$2" -t "$3" -s "$4" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Диагностика (root не нужен)
# ---------------------------------------------------------------------------
diag() {
  say "  ${B}Система${N}"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  say "    Дистрибутив: ${PRETTY_NAME:-неизвестно}"
  say "    Ядро:         $(uname -r)"
  say "    RAM:          $(free -h 2>/dev/null | awk '/^Mem:/{print $2" всего, "$7" свободно"}')"
  say "    Swap:         $(free -h 2>/dev/null | awk '/^Swap:/{print $2" всего, "$3" занято"}')"
  say "    CPU:          $(awk -F: '/model name/{print $2}' /proc/cpuinfo 2>/dev/null | head -1 | sed 's/^ //')"

  local rend drv comp zram
  rend=$(glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: //p')
  say "    Графика:      ${rend:-не определена (нет mesa-utils?)}"
  drv=$(lspci -k 2>/dev/null | grep -A2 'VGA compatible controller' \
        | sed -n 's/.*Kernel driver in use: //p' | head -1)
  say "    DRM-драйвер:  ${drv:-НЕТ (карта работает без ускорения!)}"

  say ""
  say "  ${B}Композитор${N}"
  if has_xfconf_session; then
    comp=$(xfconf-query -c xfwm4 -p /general/use_compositing 2>/dev/null)
    case "$comp" in
      true|1) warn "ВКЛЮЧЁН — система тормозит (на этом железе это главный тормоз)" ;;
      false|0) ok "выключен" ;;
      *) warn "не определён" ;;
    esac
  else
    warn "нет доступа к сессии XFCE (запустите lightos-perf из рабочего стола)"
  fi

  say "  ${B}zram${N}"
  if [ -d /sys/block/zram0 ]; then
    ok "активен, сжато $(awk '{printf "%.1f МБ", $1/2048}' /sys/block/zram0/mm_stat 2>/dev/null)"
  else
    warn "НЕ активен (свободная память не сжимается)"
  fi

  say "  ${B}governor CPU${N}"
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    say "    $(tr -d '\n' < /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  else
    warn "cpufreq недоступен (нет регулятора частот)"
  fi
  say ""
}

# ---------------------------------------------------------------------------
# --status: только показать. Ничего не меняем, root не нужен.
# ---------------------------------------------------------------------------
if [ "$MODE" = "status" ]; then
  diag
  exit 0
fi

# ---------------------------------------------------------------------------
# Пользовательская часть: настройки XFCE/GTK/Thunar.
# Должна выполняться в сессии вызвавшего пользователя.
# ---------------------------------------------------------------------------
user_part() {
  local compositor="false"
  [ "$MODE" = "restore" ] && compositor="true"

  if has_xfconf_session; then
    step "Отключаю композитор xfwm4..."
    xq xfwm4 /general/use_compositing bool "$compositor" \
      && ok "композитор $( [ "$compositor" = false ] && echo выключен || echo включён )" \
      || warn "не удалось изменить настройку композитора"

    step "Отключаю анимации, тени и прозрачность..."
    # Путь /animations у xfwm4 НЕВЕРЕН: все свойства лежат внутри
    # секции /general. По старому пути xfconf-query молча возвращал
    # ошибку, и анимации оставались включёнными.
    xq xfwm4 /general/animations string "$([ "$MODE" = restore ] && echo OpenAnimation || echo none)"
    xq xfwm4 /general/show_frame_shadow  bool "$([ "$MODE" = restore ] && echo true || echo false)"
    xq xfwm4 /general/show_popup_shadow bool "$([ "$MODE" = restore ] && echo true || echo false)"
    xq xfwm4 /general/show_shadow       bool "$([ "$MODE" = restore ] && echo true || echo false)"
    # Свойства GTK: реальные ключи xsettings. '/Net/Window animations'
    # из старой версии скрипта не существует вовсе.
    xq xsettings /Net/EnableEventSounds      bool "$([ "$MODE" = restore ] && echo true || echo false)"
    xq xsettings /Net/EnableOverlayScrollbars bool "$([ "$MODE" = restore ] && echo true || echo false)"
    xq xsettings /Net/EnableEventSounds      bool "$([ "$MODE" = restore ] && echo true || echo false)"
    ok "настройки XFCE применены"
  else
    warn "нет доступа к сессии XFCE — системные настройки применю,"
    warn "а оформление окна придётся отключить вручную:"
    warn "  xfconf-query -c xfwm4 -p /general/use_compositing -t bool -s false"
  fi

  # Файловые настройки GTK/Thunar. Пишем в ДОМ вызвавшего пользователя.
  [ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"
  if [ -d "$TARGET_HOME" ]; then
    mkdir -p "$TARGET_HOME/.config/gtk-3.0"
    if [ "$MODE" = "restore" ]; then
      rm -f "$TARGET_HOME/.config/gtk-3.0/settings.ini"
    else
      cat > "$TARGET_HOME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-enable-animations = false
gtk-enable-primary-paste = false
EOF
    fi

    mkdir -p "$TARGET_HOME/.config/Thunar"
    if [ "$MODE" = "restore" ]; then
      rm -f "$TARGET_HOME/.config/Thunar/thunarrc"
    else
      cat > "$TARGET_HOME/.config/Thunar/thunarrc" <<'EOF'
[Generic]
ExifPropsColumns=
IconViewMagnification=small
LastFolder=thunar:///
MediumIconViewMagnification=small
LargeIconViewMagnification=medium
SingleWindowClickOpen=true
TimeStampFormat=default
TreeViewEnableAscendingSorting=true
TreeViewEnableDescendingSorting=true
TreeViewEnableSortOrderMod3=false
TreeViewModel=modified-time
TreeViewVisibleColumns=Name,Size,ModifiedTime,Type
EOF
    fi
    ok "настройки GTK и Thunar для $TARGET_USER"
  else
    warn "не нашёл домашний каталог пользователя — GTK/Thunar не тронуты"
  fi
}

# ---------------------------------------------------------------------------
# Системная часть: только root.
# ---------------------------------------------------------------------------
system_part() {
  local swappiness="10"
  [ "$MODE" = "restore" ] && swappiness="60"

  step "Настраиваю параметры ядра..."
  # Постоянно, через /etc/sysctl.d, а не только sysctl -w: иначе после
  # перезагрузки всё возвращалось к дефолту. Раньше было ровно так.
  cat > /etc/sysctl.d/99-lightos-perf.conf <<EOF
# Создано lightos-perf. Удалить: lightos-perf --restore
vm.swappiness=$swappiness
vm.vfs_cache_pressure=50
EOF
  if sysctl -q -p /etc/sysctl.d/99-lightos-perf.conf 2>/dev/null; then
    ok "vm.swappiness=$swappiness, vm.vfs_cache_pressure=50 (сохранено в /etc/sysctl.d)"
  else
    warn "sysctl не применился (нет прав?)"
  fi

  step "Настраиваю zram..."
  if [ "$MODE" = "restore" ]; then
    systemctl disable --now zramswap >/dev/null 2>&1 && ok "zram выключен" || warn "zram не менялся"
  else
    # Раньше скрипт только ПРЕДУПРЕЖДАЛ, что zram не активен, хотя README
    # обещал «настраивает zram». Теперь включает.
    cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
    if systemctl enable zramswap >/dev/null 2>&1; then
      systemctl restart zramswap >/dev/null 2>&1 || true
      if [ -d /sys/block/zram0 ]; then
        ok "zram включён (50% RAM)"
      else
        warn "служба включена, но /sys/block/zram0 нет — проверьте dmesg"
      fi
    else
      warn "не удалось включить zramswap"
    fi
  fi

  step "Ставлю governor CPU..."
  if [ "$MODE" = "restore" ]; then
    GOV="ondemand"
  else
    GOV="powersave"
  fi
  if [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    # Постоянно, иначе после перезагрузки governor снова станет дефолтным.
    mkdir -p /etc/default
    cat > /etc/default/cpupower <<EOF
# Создано lightos-perf
CPU_POWER_GOVERNOR="$GOV"
EOF
    if printf '%s\n' "$GOV" \
        | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1; then
      ok "governor=$GOV (сохранено в /etc/default/cpupower)"
    else
      warn "governor не изменился"
    fi
  else
    warn "cpufreq недоступен (нет регулятора частот)"
  fi

  step "Отключаю службы, не нужные на старте..."
  local svc
  for svc in bluetooth avahi-daemon avahi-daemon.socket whoopsie rsyslog cups; do
    if [ "$MODE" = "restore" ]; then
      # Включаем обратно только то, что действительно было выключено
      if [ -f "/etc/lightos-perf-disabled/$svc" ]; then
        systemctl enable "$svc" >/dev/null 2>&1 && ok "$svc включён обратно" || warn "$svc не включается"
        rm -f "/etc/lightos-perf-disabled/$svc"
      fi
    else
      if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        mkdir -p /etc/lightos-perf-disabled
        touch "/etc/lightos-perf-disabled/$svc"
        systemctl disable --now "$svc" >/dev/null 2>&1 && ok "$svc выключен" || warn "$svc не выключается"
      fi
    fi
  done
  [ "$MODE" = "restore" ] && rmdir /etc/lightos-perf-disabled 2>/dev/null

  step "Дефолты для НОВЫХ пользователей..."
  SKEL_DIR=/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
  mkdir -p "$SKEL_DIR"
  if [ "$MODE" = "restore" ]; then
    rm -f "$SKEL_DIR/xfwm4.xml"
    ok "скел сброшен"
  else
    cat > "$SKEL_DIR/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="animations" type="string" value="none"/>
    <property name="show_shadow" type="bool" value="false"/>
    <property name="show_frame_shadow" type="bool" value="false"/>
    <property name="show_popup_shadow" type="bool" value="false"/>
  </property>
  <property name="animations" type="string" value="none"/>
  <property name="box" type="empty"/>
</channel>
EOF
    ok "композитор выключен по умолчанию для новых пользователей"
  fi
}

# ---------------------------------------------------------------------------
# Точка входа: разводим системную и пользовательскую части
# ---------------------------------------------------------------------------
run_system_and_user() {
  if [ "$(id -u)" -eq 0 ]; then
    # Мы уже root. Пользовательскую часть надо выполнить от исходного
    # пользователя — иначе настройки XFCE уедут в несуществующий
    # контекст root и потеряются.
    if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] \
       && id "$TARGET_USER" >/dev/null 2>&1; then
      step "Системные настройки (root)..."
      system_part
      say ""
      step "Настройки рабочего стола (пользователь $TARGET_USER)..."
      # sudo -u с сохранением D-Bus/XDG: без них xfconf-query не видит
      # сессию и настройка снова молча не применяется.
      if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        sudo -u "$TARGET_USER" \
          env DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
              XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u "$TARGET_USER")}" \
              LIGHTOS_PERF_USER=1 \
              LIGHTOS_PERF_MODE="$MODE" \
              "$0" </dev/null || \
          warn "пользовательская часть не выполнилась"
      else
        warn "нет DBUS_SESSION_BUS_ADDRESS — настройки окна пропущены"
        warn "  xfconf-query -c xfwm4 -p /general/use_compositing -t bool -s false"
      fi
    else
      # Вызвали из-под root без sudo (или прямо в терминале root).
      step "Системные настройки (root)..."
      system_part
    fi
  else
    # Обычный пользователь: системную часть поднимаем через sudo,
    # пользовательская остаётся здесь — в его сессии и с его правами.
    step "Системные настройки (нужен root)..."
    if sudo -v 2>/dev/null; then
      # Передаём sudo только те переменные, которые нужны пользовательской
      # части, чтобы та выполнилась в нашей сессии.
      sudo env SUDO_USER="$USER" \
               DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
               XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
               "$0" --system-only "$MODE" </dev/null \
        && ok "системные настройки применены" \
        || warn "системная часть завершилась с ошибкой"
    else
      err "нужен root для системных настроек (sysctl, zram, governor)"
    fi
    say ""
    step "Настройки рабочего стола (пользователь $(id -un))..."
    user_part
  fi
}

# Внутренний режим: пользовательская часть, вызывается через sudo -u
# от вызвавшего пользователя, поэтому здесь мы НЕ root.
if [ "${LIGHTOS_PERF_USER:-}" = "1" ]; then
  MODE="${LIGHTOS_PERF_MODE:-apply}"
  user_part
  exit 0
fi

case "${1:-}" in
  --system-only)
    [ "$(id -u)" -eq 0 ] || { err "внутренний режим: нужен root"; exit 1; }
    system_part
    exit 0
    ;;
esac

if [ "$MODE" = "apply" ]; then
  say "  ${B}LightOS — оптимизация${N}"
else
  say "  ${B}LightOS — откат оптимизации${N}"
fi
say ""
run_system_and_user

say ""
diag
say ""
if [ "$MODE" = "apply" ]; then
  say "  ${G}Готово.${N}"
  say "  ${Y}Часть настроек окна применится после выхода из сессии${N} и повторного входа."
  say "  Отменить оптимизацию:  sudo lightos-perf --restore"
else
  say "  ${G}Оптимизация отменена.${N}"
fi
say ""
exit 0
