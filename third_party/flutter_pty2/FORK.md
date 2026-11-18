# Локальный форк flutter_pty2

Это вендоренная копия `flutter_pty2` 3.0.0 (тег `3.0.0`,
commit `5b64d45237`) из https://github.com/SoFluffyOS/flutter_pty2.

Статус на 18.11.2026: upstream всё ещё 3.0.0, исправлений `libproc.h` и
`libutil` нет; форк остаётся нужен.

Причина форка: в upstream-версии `src/unix/pty_unix_spawn.c` подключает
`<libproc.h>` под `#if defined(__APPLE__)`. Заголовок есть только в macOS
SDK, поэтому сборка под iOS падает. Наш патч:

- подключает `<TargetConditionals.h>`;
- оставляет `<libproc.h>` и `proc_pidinfo()` только для macOS
  (`#if defined(__APPLE__) && !TARGET_OS_IPHONE`);
- на iOS использует существующий общий fallback с перебором fd;
- в `hook/build.dart` для iOS и macOS явно линкует `libutil` (там
  находится `openpty`); в upstream `util` был указан только для Linux,
  хотя CMake-сборка линкует его для всех Unix;
- в `pubspec.yaml` зависимости заданы caret-диапазонами от проверенных
  версий (`code_assets ^2.2.0`, `ffi ^2.2.0`, `hooks ^2.2.0`,
  `native_toolchain_c ^0.19.6`), фактические версии фиксирует корневой
  `pubspec.lock`. Из dev-зависимостей оставлен только `lints ^6.1.0`;
  `ffigen` и `test` не используются.

Патч не влияет на Linux/macOS/Android и не включает PTY на iOS: там
приложение использует только виртуальный Host.

Полное описание решения, порядка обновления и проверок — в
`docs/agent/PTY.md` в корне репозитория. При обновлении upstream сравните
`src/unix/pty_unix_spawn.c` и убедитесь, что guard для `libproc.h` не
потерян. Если upstream исправил это сам, локальный патч можно удалить.
