# ProbablyWorks server

Headless-сервер ProbablyWorks: SQLite, HTTP API, планировщик, MCP и выполнение
команд без GUI.

## Запуск

Linux/macOS:

```bash
./bin/pw_server --port 7787
```

Windows:

```powershell
.\bin\pw_server.exe --port 7787
```

Без `--data-dir` сервер использует стандартный каталог приложения для
текущей ОС.

Полезные аргументы:

- `--port 0` — выбрать свободный порт;
- `--bind 127.0.0.1` — оставить API только на loopback (по умолчанию);
- `--print-token` — напечатать токен API;
- `--rotate-token` — выпустить новый токен.

Токен и секреты хранятся в OS-keyring, если он доступен. В headless-режиме
используется файл `secrets.json` с правами `0600`; переменные окружения
`PROBABLY_WORKS_OPENROUTER_KEY`/`OPENROUTER_API_KEY` и
`PROBABLY_WORKS_API_TOKEN` имеют приоритет.

## Подключение GUI

1. Запустить сервер.
2. В GUI добавить удалённый профиль.
3. Указать адрес `http://127.0.0.1:7787` и токен.

Для доступа по сети не открывайте порт напрямую: используйте SSH-туннель,
VPN или TLS reverse proxy. Подробности — в `docs/agent/DAEMON.md`.
