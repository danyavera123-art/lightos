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
# Композитор ВЫКЛЮЧЕН: на Intel GMA / Radeon Cedar он съедает 15-30% CPU
# в обычной работе и 30-60% FPS в играх. Вернуть:
#   xfconf-query -c xfwm4 -p /general/use_compositing -t bool -s true
xfconf-query -n -c xfwm4    -p /general/use_compositing -t bool -s false      2>/dev/null || true
xfconf-query -n -c xfwm4    -p /animations              -t string -s none     2>/dev/null || true
xfconf-query -n -c xfwm4    -p /general/show_shadow     -t bool   -s false    2>/dev/null || true

# Подсказка о первых шагах: проверить драйверы и ускорение
mkdir -p "$HOME/Desktop"
cat > "$HOME/Desktop/lightos-Что-делать.txt" 2>/dev/null <<'EOF'
LightOS — первые шаги
=====================

1. Проверьте видеокарту:
     glxinfo -B | grep "OpenGL renderer"
   Если написано "llvmpipe" или "Intel(R) HD Graphics", а у ноутбука есть
   дискретная карта — поставьте драйвер: Центр приложений -> Драйверы.

2. Проверить Wi-Fi и звук: там же, кнопка "Драйверы".

3. Ускорить систему:
     lightos-perf.sh
   (отключает композитор и анимации — на этом ноутбуке это заметно
   помогает и в обычной работе, и в играх)

4. Проверить, есть ли обновление LightOS:
     sudo lightos-update.sh --check
EOF
chmod +x "$HOME/Desktop/lightos-Что-делать.txt" 2>/dev/null || true

# Обои (для каждого монитора)
for MON in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -oP '(?<=/backdrop/screen0/).*?(?=/workspace0)' | sort -u); do
  xfconf-query -n -c xfce4-desktop -p "/backdrop/screen0/$MON/workspace0/last-image" -t string -s "/usr/share/backgrounds/lightos-wallpaper.png" 2>/dev/null || true
  xfconf-query -n -c xfce4-desktop -p "/backdrop/screen0/$MON/workspace0/image-style" -t int -s 5 2>/dev/null || true
done

touch "$FLAG"
exit 0