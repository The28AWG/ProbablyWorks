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

# Добавить архитектуру в имя артефакта (так делает CI)
dart run tool/package/package.dart linux appimage,deb --artifact-suffix=-x64
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

## CI/CD

В репозитории два workflow:

- `.github/workflows/ci.yml` — форматирование, `flutter analyze`, `flutter test`
  и тесты пакетов на каждый push в `main` и pull request. DCM в CI не
  запускается: бесплатная лицензия не подходит для CI, проверка остаётся
  локальной;
- `.github/workflows/release.yml` — сборка релиза по тегу `v<version>`.

Релиз собирается на четырёх runner'ах:

| Runner | Форматы | Суффикс |
| --- | --- | --- |
| `ubuntu-latest` | AppImage, DEB, tar.gz, zip | `-x64` |
| `windows-latest` | EXE, zip | `-x64` |
| `macos-latest` (arm64) | DMG, zip | `-arm64` |
| `macos-15-intel` | DMG, zip | `-x64` |
| `ubuntu-24.04` (snap) | Snap (`amd64`) | — |

После успешной сборки workflow скачивает все артефакты, создаёт
`SHA256SUMS.txt` и публикует GitHub Release с автоматическими release notes.
Имена файлов содержат версию, платформу и архитектуру, например
`probably_works-1.0.0+1-linux-x64.AppImage` и
`probably_works-1.0.0+1-windows-x64-setup.exe`.

Порядок выпуска:

```bash
# 1. Обновить version в pubspec.yaml, например 1.0.0+2
# 2. Закоммитить изменение
git tag v1.0.0+2
git push origin main
git push origin v1.0.0+2
```

Тег обязан совпадать с `version` из `pubspec.yaml`: workflow проверяет это до
сборки. Для проверки без релиза можно запустить `Release` вручную через
`workflow_dispatch` — артефакты будут доступны в Actions, GitHub Release не
создаётся.

Секреты CI:

- подпись Windows и notarization macOS пока не автоматизированы. CI собирает
  рабочие артефакты, но для публичного релиза нужно добавить сертификаты
  Authenticode и Developer ID. Сейчас macOS-приложение получает ad-hoc
  подпись из `prepare_daemon.dart`.

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

## OS-keyring в пакетах

Приложение создаёт записи в keyring при первом запуске, а не в `postinst`:
Debian-скрипты работают от root и не имеют доступа к пользовательской
D-Bus-сессии. В DEB добавлены зависимости `dbus-user-session`,
`libsecret-1-0` и системные GTK-библиотеки; AppImage и Snap используют
D-Bus-сессию хоста.

На Linux демон хранит токен и секреты в Secret Service через чистый Dart
(`freedesktop_secret`), на macOS — в Keychain через `security`, на Windows —
в Credential Manager через FFI. Если keyring недоступен, включается файловый
fallback `0600`.

## Snap

Fastforge не умеет собирать Snap, поэтому он собирается отдельно из
`snap/snapcraft.yaml`. Используется `confinement: classic`: агенту нужны
произвольные команды, проекты в домашнем каталоге, `~/.ssh` и локальный
демон. GTK3 и его зависимости приходят из `stage-packages` Ubuntu 24.04,
поэтому snap не зависит от версии библиотек хоста.

Локальная сборка:

```bash
flutter build linux --release
PLATFORM=linux \
BUILD_OUTPUT_DIRECTORY=build/linux/x64/release/bundle \
  dart run tool/package/prepare_daemon.dart
snapcraft pack --destructive-mode
```

`--destructive-mode` требует Ubuntu 24.04 без подключённого Ubuntu Pro.
Snap получается для `amd64`. В CI Snap собирается в закреплённом Docker-образе
Snapcraft: GitHub runner не может достучаться до Snap Store, чтобы установить
Snapcraft через snapd.

Что нужно для публикации в Snap Store:

1. Аккаунт Snap Store с подтверждённым email и подписанным Developer
   Agreement (без него `snapcraft register` возвращает `user-not-ready`).
2. Зарегистрированное имя `probably-works`:
   ```bash
   snapcraft login
   snapcraft register probably-works
   ```
3. Для загрузки из CI — экспортированный токен:
   ```bash
   snapcraft export-login \
     --snaps=probably-works \
     --channels=edge,stable \
     --acls=package_access,package_push,package_release -
   ```
   Его содержимое добавляется в GitHub Secret `SNAPCRAFT_STORE_CREDENTIALS`.
   Workflow `Release` собирает snap и публикует его в канал `edge`; в
   `stable` версия продвигается вручную после проверки.

Classic-снапы проходят ручную проверку Store. Если публикация нужна только
через GitHub Releases, `.snap` всё равно прикрепляется к релизу.

## Ограничения

- Fastforge запускает hooks через `sh` на всех платформах, включая Windows.
  Поэтому для Windows-сборки нужен Git Bash или другой `sh`.
- Кросс-компиляции нет: Linux-пакеты собираются на Linux, Windows — на Windows,
  macOS — на macOS.
- `installed_size` в DEB задан оценкой; при значительном изменении размера
  bundle его стоит обновить.
- Интеграционный тест «установленный пакет запускает демон» пока не добавлен;
  проверяется сборка артефактов и наличие `daemon/bin/pw_server` в них.
