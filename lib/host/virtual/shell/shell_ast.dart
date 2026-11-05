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

/// Ссылка на переменную: `$NAME`, `${NAME}`, `$?`, `$1`, `$#`, `$@`, `$*`.
final class ParamPart extends WordPart {
  const ParamPart(this.name);

  final String name;
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

/// Присваивание перед командой (`NAME=value`) или сама переменная без команды.
final class Assignment {
  const Assignment(this.name, this.value);

  final String name;
  final ShellWord value;
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
