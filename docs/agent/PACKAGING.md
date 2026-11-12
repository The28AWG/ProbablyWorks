# Упаковка desktop-приложения

Пакеты собираются через [Fastforge](https://pub.dev/packages/fastforge). Он
запускает `flutter build`, затем pre-hook `tool/package/prepare_daemon.dart`
добавляет в готовый bundle AOT-сборку демона, после чего Fastforge формирует
AppImage, DEB, DMG, EXE или архив.

Fastforge ставится глобально, а не в `dev_dependencies`: его зависимость
`flutter_app_packager` использует `archive` 3.x, а `virtual_git` — `archive`
4.x. Прямое добавление в проект ломает разрешение зависимостей.

```bash
dart pub global activate fastforge 0.6.14
export PATH="$PATH:$HOME/.pub-cache/bin"   # Windows: %APPDATA%\Pub\Cache\bin
fastforge --version
```

## Быстрый старт

```bash
# текущая ОС и форматы по умолчанию
dart run tool/package/package.dart

# Linux: AppImage, DEB, tar.gz
dart run tool/package/package.dart linux appimage,deb,tar.gz

# Windows: установщик Inno Setup и zip
dart run tool/package/package.dart windows exe,zip

# macOS: DMG и zip
dart run tool/package/package.dart macos dmg,zip
```

Артефакты складываются в `dist/<version>/`. Каталог `dist/` исключён из git.

Эквивалентная команда без обёртки:

```bash
fastforge package --platform linux --targets appimage,deb \
  --hook-pre "dart run tool/package/prepare_daemon.dart"
```

`--skip-clean` у обёртки отключает `flutter clean` перед сборкой. По умолчанию
сборка чистая. Обёртка сама выставляет `ARCH` для `appimagetool`; при прямом
вызове Fastforge на Linux задайте `ARCH=x86_64` (или `aarch64`).

## Форматы и требования

| Платформа | Форматы | Что нужно |
| --- | --- | --- |
| Linux | `appimage`, `deb`, `tar.gz`, `zip` | `appimagetool` для AppImage, `dpkg-deb` для DEB |
| Windows | `exe`, `zip` | Inno Setup 6 и `sh` в `PATH` (Fastforge запускает hooks через `sh`) |
| macOS | `dmg`, `zip` | `appdmg`, Xcode command line tools; сборка только на macOS |

RPM и Pacman не настроены: для них нужны `rpmbuild` и `bsdtar`, они не входят
в стандартное окружение проекта. Snap в Fastforge отсутствует; для него нужен
отдельный `snapcraft.yaml`.

## Демон внутри пакета

`dart compile exe` не подходит: у `sqlite3` и `portable_pty` есть build hooks,
а компилятор требует `dart build`:

```bash
dart build cli --target packages/pw_server/bin/pw_server.dart -o build/daemon
```

Результат имеет раскладку:

```text
bundle/
  bin/pw_server
  lib/libsqlite3.so
  lib/libportable_pty_rs.so
```

Загрузчик нативных ассетов ищет библиотеки относительно `../lib` от
исполняемого файла, поэтому hook сохраняет именно эту структуру:

```text
<flutter bundle>/
  probably_works
  lib/...
  daemon/bin/pw_server
  daemon/lib/libsqlite3.so
  daemon/lib/libportable_pty_rs.so
```

На macOS каталог кладётся в `probably_works.app/Contents/MacOS/daemon`.
`PackagedDaemonLauncher` сначала ищет `daemon/bin/pw_server`, затем одиночный
`pw_server` рядом с GUI для совместимости со старыми пакетами.

DEB-пакет устанавливает всё в `/opt/probably_works`, AppImage — в AppDir,
Windows EXE — в каталог установки, macOS — в `.app`.

## Подпись

- **macOS.** После добавления демона подпись `.app` становится недействительной,
  поэтому hook переподписывает приложение. Без
  `PROBABLY_WORKS_CODESIGN_IDENTITY` используется ad-hoc подпись `-`: она
  подходит для локального запуска, но не для распространения. Для релиза
  задайте Developer ID и отдельно выполните notarization/staple.
- **Windows.** EXE и демон сейчас не подписываются. Для релиза нужен
  сертификат Authenticode и подпись установщика.
- **Linux.** Подпись пакетов не выполняется; при публикации добавьте подпись
  репозитория и контрольные суммы.

## Ограничения

- Fastforge запускает hooks через `sh` на всех платформах, включая Windows.
  Поэтому для Windows-сборки нужен Git Bash или другой `sh`.
- Кросс-компиляции нет: Linux-пакеты собираются на Linux, Windows — на Windows,
  macOS — на macOS.
- `installed_size` в DEB задан оценкой; при значительном изменении размера
  bundle его стоит обновить.
- Интеграционный тест «установленный пакет запускает демон» пока не добавлен;
  проверяется сборка артефактов и наличие `daemon/bin/pw_server` в них.
