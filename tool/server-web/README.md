# ProbablyWorks server + web

Дистрибутив headless-сервера и статического web-клиента в одном архиве.

Сервер и web лежат отдельно:

```text
server/   # бинарник pw_server и нативные библиотеки
web/      # статическая web-сборка
```

Launcher запускает сервер, который отдаёт `web/` и API с одного origin.

## Запуск

Linux/macOS:

```bash
./start.sh
```

Windows:

```powershell
.\start.bat
```

Launcher печатает адрес и токен. Откройте напечатанный `Web UI` в браузере и
введите токен на экране подключения.

Без launcher’а сервер можно запустить вручную:

```bash
./server/bin/pw_server --web-dir web --print-token
```

Полезные аргументы:

- `--port 0` — выбрать свободный порт;
- `--bind 127.0.0.1` — оставить сервер только на loopback (по умолчанию);
- `--print-token` — напечатать токен API;
- `--rotate-token` — выпустить новый токен.

Web и API находятся на одном origin, поэтому CORS не нужен. Для внешнего
доступа не открывайте порт напрямую: используйте SSH-туннель, VPN или TLS
reverse proxy. Полная документация — в репозитории проекта.

Токен и секреты хранятся в OS-keyring, если он доступен. В headless-режиме
используется файл `secrets.json` с правами `0600`; переменные окружения
`PROBABLY_WORKS_OPENROUTER_KEY`/`OPENROUTER_API_KEY`,
`PROBABLY_WORKS_HUGGINGFACE_TOKEN`/`HF_TOKEN` и
`PROBABLY_WORKS_API_TOKEN` имеют приоритет.
