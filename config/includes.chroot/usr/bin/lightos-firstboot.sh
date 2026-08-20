#!/bin/bash
# LightOS: применяет тему/панель/обои при первом входе пользователя
FLAG="$HOME/.config/lightos-firstboot.done"
[ -f "$FLAG" ] && exit 0

# Ждём запуска рабочего стола
sleep 3

# Тема и иконки
xfconf-query -n -c xsettings -p /Net/ThemeName   -t string -s "LightOS-Dark"  2>/dev/null || true
xfconf-query -n -c xsettings -p /Net/IconThemeName -t string -s "Papirus-Dark" 2>/dev/null || true
xfconf-query -n -c xfwm4    -p /general/theme    -t string -s "LightOS-Dark"  2>/dev/null || true
xfconf-query -n -c xfwm4    -p /general/use_compositing -t bool -s true       2>/dev/null || true

# Обои (для каждого монитора)
for MON in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -oP '(?<=/backdrop/screen0/).*?(?=/workspace0)' | sort -u); do
  xfconf-query -n -c xfce4-desktop -p "/backdrop/screen0/$MON/workspace0/last-image" -t string -s "/usr/share/backgrounds/lightos-wallpaper.png" 2>/dev/null || true
  xfconf-query -n -c xfce4-desktop -p "/backdrop/screen0/$MON/workspace0/image-style" -t int -s 5 2>/dev/null || true
done

touch "$FLAG"
exit 0