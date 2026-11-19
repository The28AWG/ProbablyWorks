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

`dart compile exe` не подходит: у `sqlite3` и `flutter_pty2` есть build hooks,
а компилятор требует `dart build`:

```bash
dart build cli --target packages/pw_server/bin/pw_server.dart -o build/daemon
```

Результат имеет раскладку:

```text
bundle/
  bin/pw_server
  lib/libsqlite3.so
  lib/libflutter_pty2.so
```

Загрузчик нативных ассетов ищет библиотеки относительно `../lib` от
исполняемого файла, поэтому hook сохраняет именно эту структуру:

```text
<flutter bundle>/
  probably_works
  lib/...
  daemon/bin/pw_server
  daemon/lib/libsqlite3.so
  daemon/lib/libflutter_pty2.so
```

Кроме `sqlite3` и `flutter_pty2`, в `lib` попадают библиотеки llama.cpp из
build hook `llamadart` (рантайм скачивается при первой сборке и кэшируется).
Если нужен только CPU, задайте `hooks.user_defines.llamadart` в корневом
`pubspec.yaml`; полный список ключей — в [LOCAL_MODELS.md](LOCAL_MODELS.md).

На Android и iOS приложение дополнительно зависит от `background_downloader`:
он добавляет WorkManager (Android) и background `URLSession` (iOS), своих
foreground-сервисов и разрешений сверх уже объявленных `POST_NOTIFICATIONS` и
`FOREGROUND_SERVICE_DATA_SYNC` не требуется. Плагин требует Kotlin 2.1+ (в
проекте 2.4.0) и iOS 14+ (в проекте 16.4). Уведомления канала загрузки
локализованы через `android/app/src/main/res/values*/strings.xml`.

На macOS каталог кладётся в `probably_works.app/Contents/MacOS/daemon`.
`PackagedDaemonLauncher` сначала ищет `daemon/bin/pw_server`, затем одиночный
`pw_server` рядом с GUI для совместимости со старыми пакетами.

DEB-пакет устанавливает всё в `/opt/probably_works`, AppImage — в AppDir,
Windows EXE — в каталог установки, macOS — в `.app`.

## CI/CD

В репозитории три workflow:

- `.github/workflows/ci.yml` — форматирование, `flutter analyze`,
  `flutter test`, тесты всех пакетов и release-сборки обоих web-entrypoint’ов
  на каждый push в `main` и pull request. DCM в CI не запускается из-за
  лицензии; для него есть `tool/ci/check_local.sh` и необязательный pre-push
  hook;
- `.github/workflows/parity.yml` — проверка git/bash на закреплённых и
  системных версиях;
- `.github/workflows/release.yml` — сборка релиза по тегу `v<version>`.
  Перед подготовкой исходников он вызывает CI целиком, поэтому тег не может
  указывать на коммит без пройденных проверок.

Релиз собирается на четырёх runner'ах:

| Runner | Форматы | Суффикс |
| --- | --- | --- |
| `ubuntu-latest` | AppImage, DEB, tar.gz, zip | `-x64` |
| `windows-latest` | EXE, zip | `-x64` |
| `macos-latest` (arm64) | DMG, zip | `-arm64` |
| `macos-15-intel` | DMG, zip | `-x64` |
| `ubuntu-24.04` (snap) | Snap (`amd64`) | — |

Сначала job `checks` вызывает CI целиком: форматирование, analyze, тесты,
обе web-сборки и интеграционные проверки. После него `prepare` делает
`flutter pub get`, генерацию l10n/DI и `build_runner`. Готовые
сгенерированные файлы уходят в artifact `generated-sources`;
платформенные job'ы скачивают его и не повторяют генерацию и тесты.
`flutter pub get` в них остаётся: package config привязан к ОС и путям
runner'а.

### Проверка состава сборок

Отдельный workflow `.github/workflows/platforms.yml` собирает Linux, Windows,
macOS и iOS simulator на изменения в коде и упаковке. После сборки
`tool/ci/check_bundle.dart` проверяет, что в bundle есть GUI, `LICENSE`,
`NOTICES`, шрифты, ассеты, актуальный `build-info.json` и демон с
нативными библиотеками. Демон запускается с `--help`, чтобы проверить
загрузку AOT-бинарника.

iOS входит в проверку как simulator-сборка. Настоящий локальный PTY там не
нужен: на iOS приложение использует только виртуальный Host. Но зависимость
`flutter_pty2` обязана собрать dynamic code asset, иначе Flutter не примет
статическую библиотеку. Поэтому пакет лежит в `third_party/flutter_pty2` с
локальным патчем `libproc.h`; причина форка и порядок обновления описаны в
[PTY.md](PTY.md).

Это проверка упаковки, а не поведения ОС: установка и ручные сценарии на
реальных машинах в неё не входят. Если пользователь сообщает о проблеме
конкретной платформы, она оформляется отдельным issue.

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

## Standalone-сервер

Сервер собирается отдельно от GUI, чтобы его можно было поставить на машину
без desktop-клиента:

```bash
dart run tool/package/package_server.dart --platform=linux --arch=x64
```

Артефакты кладутся в `dist/<version>/`:

- `probably-works-server-<version>-linux-x64.tar.gz`;
- `probably-works-server_<version>_amd64.deb`;
- `probably-works-server-<version>-macos-arm64.tar.gz`;
- `probably-works-server-<version>-macos-x64.tar.gz`;
- `probably-works-server-<version>-windows-x64.zip`.

Внутри архива — `probably-works-server/bin/pw_server`, `lib/` с нативными
библиотеками, README и LICENSE. Запуск:

```bash
./probably-works-server/bin/pw_server --data-dir <path> --port 7787
```

DEB ставит бинарник в `/opt/probably-works-server`, а команду — в
`/usr/bin/pw-server`. Сервер не требует GTK и работает headless. Release
workflow собирает сервер для Linux x64, Windows x64, macOS arm64 и x64 и
прикладывает архивы к GitHub Release.

## Web и server + web

Web-клиент выпускается отдельно от сервера и в связке с ним. Это разные
артефакты с разными целями.

Статический web-клиент использует hash-навигацию и не требует rewrite:

```bash
dart run tool/package/package_web.dart --web-dir=build/web-static
```

Артефакт: `probably-works-web-<version>.tar.gz` (на Windows `.zip`). Внутри —
готовая статика и README. Сервер запускается отдельно; для браузера
настраивается `--allow-origin`.

Дистрибутив «сервер + web» собирает `package_server_web.dart`:

```bash
dart run tool/package/package_server_web.dart \
  --platform=linux --arch=x64 --web-dir=build/web-hosted
```

Артефакт: `probably-works-server-web-<version>-<platform>-<arch>.tar.gz`
(на Windows `.zip`). Внутри отдельно `server/` и `web/`, launcher
`start.sh`/`start.bat`, README и LICENSE. Launcher запускает сервер с
`--web-dir web`. Web для этого варианта собирается из
`lib/main_web_hosted.dart` с path-стратегией.

Release workflow собирает оба варианта web (`main_web.dart` и
`main_web_hosted.dart`) и упаковывает сервер+web на Linux, Windows и macOS.
Подробности — в [docs/web/SERVER_WEB.md](../web/SERVER_WEB.md).

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
