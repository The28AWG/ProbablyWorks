# Server + Web

Дополнительный релиз ProbablyWorks: сервер и web-клиент в одном дистрибутиве.
Серверный бинарник и web-файлы остаются отдельными компонентами: сервер
читает каталог `web/` с диска, статика не встраивается в бинарник.

```text
probably-works-server-web/
  server/
    bin/pw_server
    lib/
  web/
    index.html
    ...
  start.sh
  start.bat
  README.md
  LICENSE
```

`start.sh`/`start.bat` запускают сервер с `--web-dir web`.

## Три независимых релиза

| Релиз | Что внутри | URL | Сервер |
|---|---|---|---|
| Server | только `pw_server` | — | пользователь запускает сам |
| Web | только статика | hash `/#/a/...` | внешний, отдельно |
| Server + Web | `server/` и `web/` рядом | path `/a/...` + fallback | запускает launcher или пользователь |

Server-only и web-only можно использовать вместе: web на статическом
хостинге, сервер отдельно, CORS через `--allow-origin`. Bundled-вариант нужен,
чтобы не настраивать два origin и rewrite вручную.

## Сборка

Web для bundled-варианта использует path-стратегию:

```bash
flutter build web -t lib/main_web_hosted.dart --wasm --release \
  --enable-wasm-deferred-loading -o build/web-hosted --base-href=/
```

Web-only релиз использует hash-стратегию и не требует rewrite:

```bash
flutter build web -t lib/main_web.dart --wasm --release \
  --enable-wasm-deferred-loading -o build/web-static --base-href=/
```

Упаковка:

```bash
# статический web
dart run tool/package/package_web.dart --web-dir=build/web-static

# сервер + web
dart run tool/package/package_server_web.dart \
  --platform=linux --arch=x64 --web-dir=build/web-hosted
```

Оба скрипта без `--web-dir` собирают соответствующую web-сборку сами.
Артефакты кладутся в `dist/<version>/`.

## Wasm и заголовки

Сборка с `--wasm` содержит оба варианта: WebAssembly для браузеров с
WasmGC и JS-fallback для остальных. Выбор делает `flutter_bootstrap.js` при
старте. В Flutter 3.50 Wasm по умолчанию включён для Chromium 137+; Safari и
Firefox получают JavaScript, пока для них явно не включён `wasmAllowList`.

Отложенные экраны приходят отдельными файлами: JS-части называются
`main.dart.js_*.part.js`, Wasm-модули — `main.dart_module*.wasm`. Их нужно
отдавать вместе с остальной сборкой и не кэшировать надолго: имена не содержат
хэш. `pw_server` отдаёт их с правильным `Content-Type` и `no-cache`.

Многопоточный Skwasm включается только при cross-origin isolation. Сервер
`pw_server` выставляет для HTML-документа:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Без этих заголовков Wasm работает в однопоточном режиме — это допустимый
режим, но медленнее. На ассеты и ответы API заголовки не ставятся.

Внешний статический хостинг должен отдавать `.wasm` с
`Content-Type: application/wasm`, а `.mjs` — как JavaScript. Заголовки
изоляции на нём настраиваются отдельно; если хостинг их не поддерживает,
Wasm останется однопоточным.

## URL rewrite

В bundled-варианте браузер видит обычные path-URL:

```text
/connect
/a/<profileId>/chats
/a/<profileId>/settings/general
```

Сервер отдаёт `index.html` для неизвестных не-API путей без расширения.
Правила:

- `/api/**` — всегда API;
- `/api/v1/health` — без токена;
- `/api/v1/**` — Bearer-токен;
- `/` и SPA-маршруты — `index.html`;
- `assets/**`, `canvaskit/**`, `icons/**` — только реальные файлы;
- отсутствующий `.js`/`.mjs`/`.css`/`.wasm` — `404`, не `index.html`.

Статика публичная, API защищён токеном. Web должен находиться в корне origin:
`RemoteAgentApi` обращается к `/api/v1` от корня.

## Запуск

Linux/macOS:

```bash
./start.sh
```

Windows:

```powershell
.\start.bat
```

Launcher печатает адрес и токен. Откройте `Web UI` в браузере и введите токен
на экране подключения. В bundled-сборке адрес сервера уже подставлен из
текущего origin.

Вручную:

```bash
./server/bin/pw_server --web-dir web --print-token
```

Для внешнего доступа используйте SSH-туннель, VPN или TLS reverse proxy.
Встроенного TLS нет. Не открывайте порт демона напрямую.

## Безопасность

- `--web-dir` не выходит за пределы указанного каталога: проверяются
  канонические пути и symlink.
- Скрытые файлы и сегменты с `\`/`/`/NUL после декодирования отклоняются.
- Статика не попадает в журнал API, чтобы загрузка приложения не забивала
  `api-access.log`.
- Токен по-прежнему обязателен для API; статическая страница без него не
  получает данные.
- Токен в браузере хранится в `FlutterSecureStorage` (`localStorage`). Это
  ограничение браузерной модели; не размещайте web на чужом origin.

## Релизные артефакты

- `probably-works-server-<version>-<platform>-<arch>.tar.gz` — только сервер.
- `probably-works-web-<version>.tar.gz` (на Windows `.zip`) — только статика.
- `probably-works-server-web-<version>-<platform>-<arch>.tar.gz` — сервер и
  web рядом.

Артефакты собираются в GitHub Actions. При пуше тега `v<version>` они
прикрепляются к GitHub Release; при ручном `workflow_dispatch` остаются
доступны только как artifacts запуска.
