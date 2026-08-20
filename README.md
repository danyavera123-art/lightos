# LightOS

Лёгкий дистрибутив на базе **Debian 12 (bookworm)** для слабых ПК.

- **Рабочий стол:** XFCE с тёмной темой LightOS-Dark (около 500–700 МБ RAM в простое)
- **Установщик:** Calamares — выбор языка, раскладки, имени пользователя и пароля, выбор диска (стирание или ручная разметка)
- **В системе:** Центр приложений (opencode, Google Chrome, Discord, VLC, Telegram, GIMP и др.), автоустановка драйверов (Wi-Fi, звук, клавиатура, видео), терминал
- **Объём:** ISO ~2.5–3 ГБ, установленная система ~4–5 ГБ (без тяжёлых программ ~3.5 ГБ)

---

## 1. Требования для сборки

- Windows 10/11 с **WSL2** (Ubuntu 22.04 или 24.04) — либо любой Linux
- ~12 ГБ свободного места на диске
- Интернет (при сборке скачиваются пакеты Debian)

## 2. Подготовка WSL2 (на Windows)

Открой `PowerShell` **от имени администратора**:

```powershell
wsl --install
```

Перезагрузись, затем установи Ubuntu (магазин Microsoft или `wsl --install -d Ubuntu`).
После установки открой терминал Ubuntu:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y live-build debootstrap xorriso isolinux syslinux-common squashfs-tools mtools dosfstools genisoimage grub-efi-amd64-bin
```

## 3. Копирование проекта и сборка

Скопируй папку `lightos` в домашний каталог Ubuntu:

```bash
cp -r /mnt/c/Users/<твой_пользователь>/Documents/Default\ Project/lightos ~/lightos
cd ~/lightos
chmod -R +x build.sh config/hooks config/includes.chroot/usr/bin
sudo ./build.sh
```

Сборка идёт 30–90 минут. Готовый образ появится в `~/lightos`:

```
live-image-amd64.hybrid.iso
```

## 4. Запись на флешку и установка

1. Запиши ISO на флешку: **Rufus** (режим DD) или **balenaEtcher**, либо закинь через **Ventoy**.
2. Загрузи ПК с флешки (выбери её в BIOS, обычно клавиша F12/F11/Del).
3. В live-системе нажми иконку **«Установить LightOS»** на рабочем столе (или в меню «Пуск»).
   > В live-режиме вход автоматический. Пользователь live: `lightos`, пароль: `lightos`.
4. Пройди мастер: язык → раскладка → имя пользователя и пароль → выбор диска → установка.
5. После завершения нажми «Перезагрузить», вытащи флешку и загрузись с диска.

> Для старого ПК (i3 1 поколения) подходит и BIOS (MBR), и UEFI — образ гибридный, поддерживает оба.

## 5. Первое включение после установки

- Войди под созданным пользователем (пароль, который задал в мастере).
- Автоматически применится тема, панель и обои.
- Открой **Центр приложений** (иконка на рабочем столе или в меню «Пуск») и установи:
  - **opencode** (CLI-ассистент, официальный скрипт установки),
  - **Google Chrome**, **Discord**, **VLC**, **Telegram**, **GIMP** и др.
- Кнопка **«Драйверы»** в центре приложений докачает нужные прошивки/драйверы.
- Терминал: `sudo apt update && sudo apt install <пакет>` — так ставятся любые программы из репозиториев Debian.

## 6. Как это устроено

```
lightos/
├── build.sh                      # сборка ISO через live-build
├── config/
│   ├── package-lists/            # пакеты ядра/графики/приложений
│   ├── hooks/live/               # скрипты сборки (пользователь live, авто-вход, иконки)
│   └── includes.chroot/          # файлы, попадающие в систему
│       ├── etc/calamares/        # настройки установщика (модули + брендинг)
│       ├── etc/xdg/xfce4/        # тема, панель, обои по умолчанию
│       ├── usr/bin/              # центр приложений, скрипты установки/драйверов
│       └── usr/share/themes/     # тема LightOS-Dark
└── README.md
```

### Основные скрипты

| Файл | Назначение |
|------|-----------|
| `usr/bin/lightos-install-copy.sh` | копирует live-систему на целевой диск (во время установки) |
| `usr/bin/lightos-install-post.sh` | настройка после копирования: хостнейм, службы, локаль, zram |
| `usr/bin/lightos-appcenter.sh`    | Центр приложений LightOS (opencode, Chrome, Discord, драйверы…) |
| `usr/bin/lightos-firstboot.sh`    | применяет тему/обои при первом входе |

### Экономия ресурсов

- XFCE вместо тяжёлых окружений, отключены лишние службы
- **zram** — сжатие части ОЗУ (настройка `/etc/default/zramswap`)
- Без LibreOffice/Thunderbird/Evolution «из коробки» — ставятся через Центр приложений
- Убрать Firefox (`sudo apt purge firefox-esr`) — освободит ~300 МБ на диске

## 7. Частые вопросы

**Не работает Wi-Fi после установки?**
Открой Центр приложений → «Драйверы», затем перезагрузи ПК. Если и это не помогло — включи в BIOS разблокировку сети (`Wireless LAN` / `WLAN`).

**Не грузится с флешки?**
Проверь порядок загрузки в BIOS и отключи Secure Boot (если есть).

**Хочу поменять раскладку / системный язык.**
Раскладка: `Alt+Shift` (настраивается в мастере установки). Язык: `sudo dpkg-reconfigure locales`.

## 8. Скачивание готового образа с GitHub

Последний собранный ISO лежит в релизах репозитория. Скачать одной командой:

```bash
curl -L -o lightos.iso "https://github.com/danyavera123-art/lightos/releases/latest/download/lightos.iso"
```

Или через GitHub CLI:

```bash
gh release download --repo danyavera123-art/lightos --pattern "*.iso" --clobber
```

Исходники проекта: https://github.com/danyavera123-art/lightos