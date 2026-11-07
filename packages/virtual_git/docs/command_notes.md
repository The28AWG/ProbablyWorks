# Пояснения к реализованным командам

Здесь — уточнения к строкам отчёта в `README.md` («Основные и прочие команды»), которые не помещаются в единый формат списка. Обновляйте файл вместе с изменением поведения команд.

Сверка с системным git на машине (код выхода и stdout/stderr) для `backfill` и `git maintenance run` — в `test/git_parity_steps_test.dart`. Остальные подкоманды `maintenance` (регистрация в планировщике, lock конфига) или `git scalar` (у дистрибутива часто нет встроенной команды у `git`) с эталоном один в один не гоняются.

Сценарий `format-patch` → `git am` для одного коммита — там же (`git am из format-patch`).

`git am` пробрасывает в `apply` политику `--whitespace` (в т.ч. `error` / `fix`), `--reject`, режимы `--ignore-space-change` / `--ignore-whitespace`; при `--continue` флаги читаются из `.git/rebase-apply`. `--quoted-cr` обрабатывается для тела письма до `diff --git` (`nowarn` / `warn` / `strip`). Тема коммита — логика `mailinfo` через `-k` / `-b` (`--keep` / `--keep-non-patch`); при `-m` в конец сообщения добавляется строка `Message-ID:` из заголовка.

`--interactive`, `--gpg-sign`, `--rerere-autoupdate` и флаги хуков (`--verify`, `--no-verify`) дают `fatal` и код 128. `--utf8` включён по умолчанию, как у git: письмо в UTF-8 или US-ASCII применяется как есть. Объявленная другая кодировка (`Content-Type` или RFC 2047) — `fatal: cannot convert from … to UTF-8`, без подмены байт. `git gc` без флагов вызывает prune; неизвестная опция и лишний аргумент — код 129, молчаливого успеха нет.

## `commit`

Сообщение собирается из `-m` / `-F` / `-C` / `--amend` / `--fixup` / `--squash`, затем cleanup (`whitespace`, `strip`, `verbatim`; `scissors` без редактора совпадает с `whitespace`), `--signoff` и `--trailer`. `-a` добавляет в индекс правки отслеживаемых файлов. Пути без `-i` — частичный коммит `--only`: в коммит попадают только они, остальные проиндексированные правки остаются в индексе. `-i` индексирует пути и коммитит весь индекс. `--dry-run`, `--short`, `--porcelain` и `--long` печатают статус и не создают коммит. `--date` и `--author` меняют автора; `--reset-author` — только вместе с `-C`, `-c` или `--amend`.

Редактор не запускается. Если git открыл бы его (`git commit` при наличии индекса, `-e`, `-c`, `--fixup=amend|reword`, `--squash` без `-m`), stderr — те же две строки `EDITOR unset`, код 1. `--gpg-sign`, `--interactive`, `--patch` и флаги хуков (`--verify`, `--no-verify`, `--post-rewrite`, `--no-post-rewrite`) дают `fatal` и код 128: молчаливого успеха нет. Относительные даты (`yesterday`) не разбираются. `--short --branch` показывает ahead/behind, если в конфиге есть upstream и ссылка `refs/remotes/...`. Сверка — `test/git_commit_parity_test.dart`.

## `branch`

Список, создание, удаление, переименование, копирование и upstream. Формат по умолчанию совпадает с git 2.53: `* ` у текущей ветки, два пробела у остальных, `remotes/` при `-a`, цвета `--color=always` (`\x1b[32m` / `\x1b[31m` / `\x1b[34m` и сброс `\x1b[m`). `-v` печатает короткий хеш и тему, `-vv` — ещё и upstream (`[origin/main]`, `ahead` / `behind` / `gone`). `--format` понимает `refname`, `objectname`, `HEAD`, `upstream`, `symref`, `contents`, даты автора и коммитера, `align` и `if`/`then`/`else`/`end`. Неизвестное поле — `fatal: unknown field name`, код 128.

`--contains`, `--merged`, `--points-at` фильтруют по предкам. `--sort` (в том числе `version:refname` и дата) и `--column` (`row`, `plain`, `dense`, `auto` без tty — одна колонка) меняют вывод. `--track=direct|inherit` и автотрекинг с remote-ветки пишут `branch.<имя>.remote` / `merge`. `-c` копирует reflog и секцию конфига, `-m` переносит их.

Редактор `--edit-description` не запускается: одна строка `EDITOR unset`, код 1. `--recurse-submodules` без `submodule.propagateBranches=true` даёт тот же `fatal`, что git. Если ключ включён и в индексе есть gitlink или есть `.gitmodules`, команда завершается `fatal: --recurse-submodules with submodules is not supported`: обхода подмодулей нет. Неизвестная опция — код 129. Сверка — `test/git_branch_parity_test.dart`.

## `format-patch`

Серия писем в mbox: диапазон `A..B` / `A...B`, `since` (коммиты после ревизии, достижимые из `HEAD`) и `-N` (последние N от ревизии, по умолчанию `HEAD`). Без ревизии и без `-N` команда ничего не печатает: upstream не подставлен. Несколько отдельных ревизий без `..` отклоняются с `fatal`.

Письмо совпадает с git по заголовкам (`From`, `Date` в RFC 2822, `Subject` с `[PATCH n/m]`, `-v`, `--rfc`, `--subject-prefix`), телу, `Signed-off-by`, diffstat и unified diff. `--no-binary` оставляет строку `Binary files differ`; без него для двоичного файла пишется `GIT binary patch` (literal, zlib). Подпись по умолчанию — `0.1.0` (строка `git version` апплета), не версия системного git; `--signature`, `--signature-file` и `--no-signature` работают как у git.

`--thread=shallow|deep` ставит `Message-ID` / `In-Reply-To` / `References`. Метка времени в `Message-ID` — момент запуска, как `time(NULL)` у git, поэтому байты расходятся на этих цифрах. Неизвестный стиль (`--thread=nope`) — код 129 и пустой stderr, как у этой сборки git. `--cover-letter`, `--cover-from-description` и `--description-file` заполняют обложку; `--range-diff` и `--interdiff` при нескольких патчах сами включают обложку, а с `--no-cover-letter` дают `fatal`. `--ignore-if-in-upstream` выбрасывает патч, если такой же diff уже есть в указанной ревизии.

Неизвестное длинное имя — `fatal: unrecognized argument` и код 128, как у этой сборки git.

## `grep`

Ищет в отслеживаемых файлах рабочего дерева, а не в `HEAD`: правка
в файле видна сразу, удалённый из дерева файл без `--cached` не ищется.
`--cached` читает blob индекса, аргумент-ревизия — дерево, `--untracked`
добавляет неотслеживаемые (игнорируемые — только с
`--no-exclude-standard`), `--no-index` обходит каталог как `grep -r`.
Образец по умолчанию — POSIX BRE, `-E` — ERE, `-F` — буквальная строка.
Несколько образцов соединяются `--and` / `--or` / `--not` и скобками;
`--all-match` оставляет файлы, где нашёлся каждый образец. Первый
не-флаг закрывает разбор опций: `-e` уже даёт образец, и следующее слово
— ревизия или путь. Флаг после образца — `fatal: option '…' must come
before non-option arguments`.

Вывод: номера строк (`-n`), колонка (`--column`), контекст (`-A`/`-B`/`-C`),
`-o`, `-c`, `-l`/`-L`, `--heading`, `--break`, `-z`, двоичные файлы (`-a`,
`-I`). `-l` перекрывает `-c`. Пустой образец совпадает со всеми строками,
но `-o` нулевые куски не печатает. Сверка с системным git —
`test/git_grep_parity_test.dart`.

Неразобранные флаги (`-P`, `--color`, `--threads`, `--textconv`, pager,
function-context, submodule) дают `error: unknown option` и код 129.
Обратные ссылки `\1` в шаблоне — `fatal` с текстом, что они не поддерживаются:
движок их не имитирует молча.

## `diff`

Разбирается только подмножество флагов из `gitDiffParseOptions` (см. `lib/src/git_diff_options.dart` и `supportedOptionLabels` в `tool/parity_policy.dart`). Реализованы: сравнение ревизий (включая `A...B` через [mergeBase], `--merge-base A B`, `-R`), индекс/рабочее дерево с `--cached`/`--staged`, `--`, pathspec; форматы вывода — unified patch (по умолчанию), `--stat` (и комбинация с `--patch-with-stat`), `--shortstat`, `--numstat`, `--name-only`, `--name-status`, `--quiet`, `--exit-code`; при `--full-index` в строках `index` печатаются полные хеши blob (без сокращения).

Остальные флаги из справки git (`--color`, rename/copy, word-diff, внешний diff и т.д.) **не** разбираются: `error: unknown option`, код 129 — как у остальных команд апплета.

## `range-diff`

Формы операндов: два диапазона `base..tip`, тройная точка `old...new`, три и четыре отдельные ревизии. Списки коммитов — [revListAncestryPath]; merge-коммиты из сравнения исключаются (как у git без `--diff-merges`; сам флаг не парсится). Сопоставление — венгерский алгоритм по «стоимости» редакционного расстояния синтетического текста (author + сообщение + unified diff к родителю или пустому дереву `4b825dc6…`), вес несовпадений — `--creation-factor`. Вывод пар и «только левая/правая» сторона; `--left-only` / `--right-only`; при `--patch` — [gitUnifiedTextDiff] между синтетическими текстами; `-U` / `--unified` — контекст патча; `--quiet`, `--exit-code`, `-s` / `--no-patch`.

Флаги вроде `--notes`, `--diff-merges`, `--stat`, `--color` и прочий полный набор diff-format из справки git **не** входят в `gitRangeDiffParseOptions`: отказ с кодом 129.

## Паритет опций и политика

Скрипт `tool/parity_report.dart` проверяет только разбор флагов (нет ли `error: unknown option`), а не совпадение текста с git.

- Карта того, какие флаги апплет **намеренно** принимает по командам из «Основные команды», и зачем остальные помечены как ожидаемый пробел — в `tool/parity_policy.dart` (`supportedOptionLabels`, `expectedOptionGaps`).
- Запуск по этой политике (и только по перечисленным в README командам, с разбором `git maintenance <подкоманда>` и `scalar <подкоманда>`): `dart run tool/parity_report.dart --policy`. Внизу печатается строка «По политике README»; неожиданные флаги остаются в блоке `нет (неожиданно):`, ожидаемые — в `ожидаемо не парсим:` с повтором краткой причины из политики.

## `backfill`

Запрос недостающих объектов идёт на удалённый `origin` по HTTP. Без файла `.git/info/promisor-filter` команда завершается успешно и ничего не запрашивает (как у системного git при отсутствии частичного клона).

## `maintenance`

Подкоманды и флаги разбираются как в git 2.53. Фактически выполняется только задача `gc` (упрощённо: достижимость и loose-объекты, см. `prune` в репозитории). Остальные задачи — no-op: нет планировщика процессов и внешнего фона, как в ограничениях пакета.

## `scalar`

Отдельная команда апплета, моделирует отдельный бинарь `scalar` (не префикс `git` до подкоманды): глобальные `-C` и `-c` разбираются отдельно от подкоманд. Подкоманд `clone` (по умолчанию с `--filter=blob:none` при отсутствии `--full-clone`), `register`, `run`, `reconfigure` и др.; `version` печатает строку версии апплета. Сценарии вроде `diagnose` и полная сетевые цепочки ограничены правилами пакета (только HTTP через `package:http` и без процессов хоста).
