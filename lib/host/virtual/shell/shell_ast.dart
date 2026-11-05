/// Дерево разбора поддерживаемого подмножества bash.
///
/// Скрипт — список цепочек `&&`/`||`, цепочка — конвейер команд. Команда бывает простой ([SimpleCommand]),
/// составной ([CompoundCommand]: подоболочка, группа, `if`, циклы, `case`) или определением функции
/// ([FunctionDefinition]). Слова хранят части (литерал, кавычки, подстановка), потому что порядок
/// расширения зависит от кавычек.
library;

/// Часть слова до расширения.
sealed class WordPart {
  const WordPart();
}

/// Текст. [quoted] = true, если он в кавычках или экранирован: такие символы не участвуют в глоббинге
/// и не режутся по пробелам.
final class LiteralPart extends WordPart {
  const LiteralPart(this.text, {this.quoted = false});

  final String text;
  final bool quoted;
}

/// Тильда в начале слова (`~` или `~/...`). Раскрывается в домашний каталог Host.
final class TildePart extends WordPart {
  const TildePart();
}

/// Ссылка на переменную: `$NAME`, `${NAME}`, `$?`, `$1`, `$#`, `$@`, `$*`, а также все формы `${...}`:
/// индекс, длина, косвенность, ключи и модификаторы. Простое `$NAME` — частный случай с видом
/// [ParamKind.value] без индекса и модификатора.
final class ParamPart extends WordPart {
  const ParamPart(
    this.name, {
    this.subscript,
    this.kind = ParamKind.value,
    this.op,
  });

  /// Имя переменной или спецпараметр. Для [ParamKind.names] — префикс имён.
  final String name;

  /// Индекс `[...]`, `[@]` или `[*]`. null — без индекса.
  final ParamSubscript? subscript;

  /// Что берётся из параметра: значение, длина, косвенное значение, ключи или имена.
  final ParamKind kind;

  /// Модификатор, который применяется к значению. null — без модификатора.
  final ParamOp? op;
}

/// Вид обращения, заданный префиксом внутри `${...}`: `#` — длина, `!` — косвенность (`${!x}`), `!x[@]` —
/// ключи массива, `!prefix*` и `!prefix@` — имена переменных с префиксом.
enum ParamKind { value, length, indirect, keys, names }

/// Индекс в `[...]` после имени переменной.
sealed class ParamSubscript {
  const ParamSubscript();
}

/// `[@]` или `[*]`: все элементы. [star] — `*`, который в кавычках склеивает элементы через IFS.
final class AllElements extends ParamSubscript {
  const AllElements({required this.star});

  final bool star;
}

/// `[выражение]`: индекс индексированного массива (арифметика) или ключ ассоциативного массива (строка).
/// [source] — исходный текст между скобками: нужен для сообщений об ошибках.
final class IndexElement extends ParamSubscript {
  const IndexElement(this.index, this.source);

  final ShellWord index;
  final String source;
}

/// Недопустимая форма `${...}`, например `${}` или `${x:}`. Как в bash, ошибка возникает при раскрытии,
/// а не при разборе: команды до неё успевают выполниться.
final class BadSubstitutionPart extends WordPart {
  const BadSubstitutionPart(this.text);

  /// Текст между `{` и `}`.
  final String text;
}

/// Модификатор `${NAME op ...}`. Операнды — вложенные слова: раскрываются только тогда, когда нужны
/// (правая часть `:-` не выполняется, если значение задано).
sealed class ParamOp {
  const ParamOp();
}

/// Вид оператора из группы «значение по умолчанию».
enum ParamDefaultKind { useDefault, assign, error, alternative }

/// `-`/`:-` (значение по умолчанию), `=`/`:=` (присвоить по умолчанию), `?`/`:?` (ошибка, если не задано),
/// `+`/`:+` (альтернатива, если задано). [nullIsUnset] — форма с двоеточием: пустое значение тоже считается
/// незаданным.
final class ParamDefaultOp extends ParamOp {
  const ParamDefaultOp(this.kind, this.word, {required this.nullIsUnset});

  final ParamDefaultKind kind;
  final ShellWord word;
  final bool nullIsUnset;
}

/// `#`, `##`, `%`, `%%`: удаление начала или конца значения по образцу. [longest] — двойной символ,
/// который удаляет самое длинное совпадение вместо самого короткого.
final class ParamTrimOp extends ParamOp {
  const ParamTrimOp({
    required this.prefix,
    required this.longest,
    required this.pattern,
  });

  /// true — с начала (`#`), false — с конца (`%`).
  final bool prefix;
  final bool longest;
  final ShellWord pattern;
}

/// Режим замены: `/` — первое совпадение, `//` — все, `/#` — в начале, `/%` — в конце.
enum ReplaceMode { first, all, prefix, suffix }

/// `/`, `//`, `/#`, `/%`: замена по образцу. [replacement] пуст, если его нет в записи.
final class ParamReplaceOp extends ParamOp {
  const ParamReplaceOp(this.mode, this.pattern, this.replacement);

  final ReplaceMode mode;
  final ShellWord pattern;
  final ShellWord replacement;
}

/// `:offset` и `:offset:length`: срез строки по байтам или списка по элементам. [length] — null, если не задан.
final class ParamSliceOp extends ParamOp {
  const ParamSliceOp(this.offset, this.length);

  final ShellWord offset;
  final ShellWord? length;
}

/// Режим смены регистра: `^` и `,` — первый символ, `^^` и `,,` — все, `~` и `~~` — переключение.
enum ParamCaseMode {
  upperFirst,
  upperAll,
  lowerFirst,
  lowerAll,
  toggleFirst,
  toggleAll,
}

/// `^`, `^^`, `,`, `,,`, `~`, `~~`. [pattern] — символы, к которым применяется смена (null — ко всем).
final class ParamCaseOp extends ParamOp {
  const ParamCaseOp(this.mode, this.pattern);

  final ParamCaseMode mode;
  final ShellWord? pattern;
}

/// Преобразование `@Q`, `@E`, `@U`, `@u`, `@L`, `@l`. [letter] — буква после `@`.
final class ParamTransformOp extends ParamOp {
  const ParamTransformOp(this.letter);

  final String letter;
}

/// Подстановка команды `$(...)` или `` `...` ``. Вывод команды, без хвостовых переводов строк.
final class CommandPart extends WordPart {
  const CommandPart(this.script);

  final ScriptNode script;
}

/// Арифметическое расширение `$((...))`. Выражение — слово: `$VAR` в нём раскрывается до вычисления.
final class ArithmeticPart extends WordPart {
  const ArithmeticPart(this.expression);

  final ShellWord expression;
}

/// Группа в двойных кавычках. Внутри неё подстановки не режутся по пробелам, а глобы не раскрываются.
final class QuotedPart extends WordPart {
  const QuotedPart(this.parts);

  final List<WordPart> parts;
}

/// Слово: последовательность частей. Пустое слово (`""`) — одно слово с пустым результатом.
final class ShellWord {
  const ShellWord(this.parts);

  final List<WordPart> parts;
}

/// Тип перенаправления файла: `<`, `>`, `>>`, `<<<`, `>&N`.
enum RedirectKind { input, output, append, hereString, dupOutput }

/// Перенаправление. [fd] — дескриптор слева от оператора (по умолчанию 0 или 1).
sealed class Redirect {
  const Redirect(this.fd);

  final int fd;
}

/// Перенаправление в файл, строку или дескриптор: `> file`, `2>&1`, `<<< text`.
final class FileRedirect extends Redirect {
  const FileRedirect(super.fd, this.kind, this.target);

  final RedirectKind kind;
  final ShellWord target;
}

/// Here-document. [body] — содержимое, уже разобранное: при кавычках в разделителе это один
/// литерал, иначе с подстановками. [terminated] — нашлась ли строка-разделитель (иначе bash печатает
/// предупреждение и использует всё до конца скрипта).
final class HeredocRedirect extends Redirect {
  const HeredocRedirect(
    super.fd, {
    required this.body,
    required this.delimiter,
    required this.terminated,
    required this.line,
    required this.eofLine,
  });

  final ShellWord body;
  final String delimiter;
  final bool terminated;

  /// Строка оператора `<<`.
  final int line;

  /// Строка конца скрипта для предупреждения о незакрытом документе.
  final int eofLine;
}

/// Элемент литерала массива `NAME=(...)`: обычный `value` или `[key]=value`. [key] — null для обычного
/// элемента. Ключ раскрывается как слово; для индексированного массива его потом вычисляет арифметика.
final class ArrayElement {
  const ArrayElement(this.value, {this.key});

  final ShellWord? key;
  final ShellWord value;
}

/// Присваивание перед командой или без неё: `NAME=value`, `NAME+=value`, `NAME[index]=value` и литерал
/// массива `NAME=(...)` / `NAME+=(...)`.
///
/// Для литерала [elements] задан, а [value] — пустое слово и не используется. [index] задан только у
/// присваивания элементу. [append] — форма с `+=`: значение дописывается, а массив дополняется.
final class Assignment {
  const Assignment(
    this.name,
    this.value, {
    this.index,
    this.elements,
    this.append = false,
  });

  final String name;
  final ShellWord value;

  /// Индекс `NAME[index]=value`: слово, которое раскрывается до вычисления или чтения ключа.
  final ShellWord? index;

  /// Элементы литерала `NAME=(...)`. null — не литерал.
  final List<ArrayElement>? elements;

  final bool append;
}

/// Команда конвейера: простая, составная или определение функции.
sealed class ShellCommand {
  const ShellCommand(this.line);

  /// Строка скрипта, на которой начинается команда. Нужна для сообщений и `$LINENO`.
  final int line;
}

/// Простая команда: присваивания, слова (первое — имя команды) и перенаправления.
final class SimpleCommand extends ShellCommand {
  const SimpleCommand({
    required this.assignments,
    required this.words,
    required this.redirects,
    required int line,
  }) : super(line);

  final List<Assignment> assignments;
  final List<ShellWord> words;
  final List<Redirect> redirects;
}

/// Составная команда. Перенаправления стоят после закрывающего слова или скобки: `done > out`.
/// Они применяются один раз ко всей конструкции, а не к каждой команде внутри.
sealed class CompoundCommand extends ShellCommand {
  const CompoundCommand(super.line, this.redirects);

  final List<Redirect> redirects;
}

/// `( список )`: выполняется в копии состояния, как подоболочка bash.
final class SubshellCommand extends CompoundCommand {
  const SubshellCommand(this.body, super.line, super.redirects);

  final ScriptNode body;
}

/// `{ список; }`: выполняется в том же состоянии, что и окружающий скрипт.
final class GroupCommand extends CompoundCommand {
  const GroupCommand(this.body, super.line, super.redirects);

  final ScriptNode body;
}

/// Ветка `if` или `elif`: условие и тело. Тело выполняется, если условие завершилось с кодом 0.
final class ConditionalBranch {
  const ConditionalBranch(this.condition, this.body);

  final ScriptNode condition;
  final ScriptNode body;
}

/// `if ... then ... [elif ...] [else ...] fi`.
final class IfCommand extends CompoundCommand {
  const IfCommand(this.branches, this.elseBody, super.line, super.redirects);

  final List<ConditionalBranch> branches;
  final ScriptNode? elseBody;
}

/// `while` и `until`: цикл, который продолжается, пока условие истинно (`while`) или ложно (`until`).
final class LoopCommand extends CompoundCommand {
  const LoopCommand(
    this.condition,
    this.body, {
    required this.until,
    required int line,
    required List<Redirect> redirects,
  }) : super(line, redirects);

  final ScriptNode condition;
  final ScriptNode body;
  final bool until;
}

/// `select NAME [in WORDS]; do ...; done`. Без `in` пункты меню — позиционные параметры.
/// Номер ответа записывается в `REPLY`, выбранное слово — в [variable].
final class SelectCommand extends CompoundCommand {
  const SelectCommand(
    this.variable,
    this.words,
    this.body,
    super.line,
    super.redirects,
  );

  final String variable;
  final List<ShellWord>? words;
  final ScriptNode body;
}

/// `for NAME [in WORDS]; do ...; done`. Без `in` (`words == null`) цикл идёт по позиционным параметрам.
final class ForCommand extends CompoundCommand {
  const ForCommand(
    this.variable,
    this.words,
    this.body,
    super.line,
    super.redirects,
  );

  final String variable;
  final List<ShellWord>? words;
  final ScriptNode body;
}

/// Чем завершается ветка `case`: `;;` — конец, `;&` — выполнить следующую ветку без проверки образца,
/// `;;&` — продолжить проверку образцов со следующей ветки. Последняя ветка без терминатора — [stop].
enum CaseTerminator { stop, fallthrough, testNext }

/// Ветка `case`: образцы через `|`, тело и терминатор.
final class CaseClause {
  const CaseClause(this.patterns, this.body, this.terminator);

  final List<ShellWord> patterns;
  final ScriptNode body;
  final CaseTerminator terminator;
}

/// `case WORD in образец) список;; ... esac`.
final class CaseCommand extends CompoundCommand {
  const CaseCommand(this.subject, this.clauses, super.line, super.redirects);

  final ShellWord subject;
  final List<CaseClause> clauses;
}

/// `((выражение))`: код 0, если значение ненулевое, иначе 1. Выражение — слово: `$VAR` и подстановки
/// раскрываются до вычисления, как в `$((...))`. Присваивания внутри выражения меняют оболочку.
final class ArithmeticCommand extends CompoundCommand {
  const ArithmeticCommand(this.expression, super.line, super.redirects);

  final ShellWord expression;
}

/// `for ((init; cond; step)); do ... done`. Любая из трёх частей может быть пустой: пустое условие истинно.
/// [init] выполняется один раз, [step] — после каждой итерации, включая `continue`.
final class ArithmeticFor extends CompoundCommand {
  const ArithmeticFor(
    this.init,
    this.condition,
    this.step,
    this.body,
    super.line,
    super.redirects,
  );

  final ShellWord? init;
  final ShellWord? condition;
  final ShellWord? step;
  final ScriptNode body;
}

/// Узел условия `[[ ... ]]`. `&&` и `||` вычисляются слева направо с коротким замыканием, `!` относится
/// к ближайшему операнду, как в bash.
sealed class CondNode {
  const CondNode();
}

/// `левое || правое`. Правая часть не вычисляется, если левая истинна.
final class CondOr extends CondNode {
  const CondOr(this.left, this.right);

  final CondNode left;
  final CondNode right;
}

/// `левое && правое`. Правая часть не вычисляется, если левая ложна.
final class CondAnd extends CondNode {
  const CondAnd(this.left, this.right);

  final CondNode left;
  final CondNode right;
}

/// `! выражение`.
final class CondNot extends CondNode {
  const CondNot(this.inner);

  final CondNode inner;
}

/// `( выражение )` внутри `[[ ]]`.
final class CondGroup extends CondNode {
  const CondGroup(this.inner);

  final CondNode inner;
}

/// Первичный операнд: слово (непустая строка истинна), унарный оператор (`-f`, `-z`) или бинарный
/// (`==`, `=~`, `-eq`). У слова [op] и [right] равны null. У унарного [left] равен null.
final class CondPrimary extends CondNode {
  const CondPrimary(this.op, this.left, this.right);

  final String? op;
  final ShellWord? left;
  final ShellWord? right;
}

/// `[[ выражение ]]`. Слова внутри не режутся по пробелам и не глобятся. Перенаправления после `]]`
/// применяются один раз, как у остальных составных команд.
final class CondCommand extends CompoundCommand {
  const CondCommand(this.expr, super.line, super.redirects);

  final CondNode expr;
}

/// `name() составная-команда` или `function name [()] составная-команда`. Само определение ничего не
/// выполняет: оно записывает функцию в состояние. Перенаправления принадлежат телу, как в bash.
final class FunctionDefinition extends ShellCommand {
  const FunctionDefinition(this.name, this.body, super.line);

  final String name;
  final CompoundCommand body;
}

/// Конвейер `a | b | c`. [negated] — префикс `!`.
final class Pipeline {
  const Pipeline(this.commands, {this.negated = false});

  final List<ShellCommand> commands;
  final bool negated;
}

/// Оператор между конвейерами: `&&` выполняет следующий при успехе, `||` — при неудаче.
enum AndOrOperator { and, or }

/// Цепочка конвейеров. [operators] на одну позицию короче [pipelines].
final class AndOrList {
  const AndOrList(this.pipelines, this.operators);

  final List<Pipeline> pipelines;
  final List<AndOrOperator> operators;
}

/// Скрипт: цепочки, разделённые `;` или переводом строки.
final class ScriptNode {
  const ScriptNode(this.lists);

  final List<AndOrList> lists;
}
