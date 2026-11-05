import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_parser.dart';

/// Текстовый слепок дерева. Формат фиксирует структуру, а не исходный текст:
/// `[...]` — слово, `'...'` — литерал в кавычках, `"..."` — двойные кавычки, `$NAME` — переменная,
/// `$(...)` — подстановка, `$((...))` — арифметика, `~` — тильда, `>f`, `2>&1`, `<<body` — перенаправления.
/// Составные команды печатаются в виде их ключевых слов: `if c; then b; fi`, `(list)`, `{ list; }`.
String _dump(ScriptNode script) => script.lists.map(_andOr).join('; ');

String _andOr(AndOrList list) {
  final buffer = StringBuffer(_pipeline(list.pipelines.first));
  for (var i = 0; i < list.operators.length; i++) {
    buffer
      ..write(list.operators[i] == AndOrOperator.and ? ' && ' : ' || ')
      ..write(_pipeline(list.pipelines[i + 1]));
  }
  return buffer.toString();
}

String _pipeline(Pipeline pipeline) {
  final body = pipeline.commands.map(_command).join(' | ');
  return pipeline.negated ? '! $body' : body;
}

String _command(ShellCommand command) => switch (command) {
  SimpleCommand() => _simple(command),
  CompoundCommand() => _compound(command),
  FunctionDefinition(:final name, :final body) => '$name() ${_command(body)}',
};

String _arith(ShellWord? word) => word == null ? '' : _word(word, inDq: true);

String? _shownWord(ShellWord? word) => word == null ? null : _word(word);

String _cond(CondNode node) => switch (node) {
  CondOr(:final left, :final right) => '${_cond(left)} || ${_cond(right)}',
  CondAnd(:final left, :final right) => '${_cond(left)} && ${_cond(right)}',
  CondNot(:final inner) => '! ${_cond(inner)}',
  CondGroup(:final inner) => '(${_cond(inner)})',
  CondPrimary(:final op, :final left, :final right) => [
    ?_shownWord(left),
    ?op,
    ?_shownWord(right),
  ].join(' '),
};

String _simple(SimpleCommand command) {
  final parts = <String>[
    for (final a in command.assignments) _assignment(a),
    for (final w in command.words) _word(w),
    for (final r in command.redirects) _redirect(r),
  ];
  return parts.join(' ');
}

String _compound(CompoundCommand command) {
  final body = switch (command) {
    SubshellCommand(:final body) => '(${_dump(body)})',
    GroupCommand(:final body) => '{ ${_dump(body)}; }',
    IfCommand(:final branches, :final elseBody) => _if(branches, elseBody),
    LoopCommand(:final condition, :final body, :final until) =>
      '${until ? 'until' : 'while'} ${_dump(condition)}; do ${_dump(body)}; done',
    ForCommand(:final variable, :final words, :final body) =>
      'for $variable'
          '${words == null ? '' : ' in ${words.map(_word).join(' ')}'}; '
          'do ${_dump(body)}; done',
    SelectCommand(:final variable, :final words, :final body) =>
      'select $variable'
          '${words == null ? '' : ' in ${words.map(_word).join(' ')}'}; '
          'do ${_dump(body)}; done',
    CaseCommand(:final subject, :final clauses) =>
      'case ${_word(subject)} in ${clauses.map(_clause).join(' ')} esac',
    ArithmeticCommand(:final expression) =>
      '((${_word(expression, inDq: true)}))',
    ArithmeticFor(:final init, :final condition, :final step, :final body) =>
      'for ((${_arith(init)}; ${_arith(condition)}; ${_arith(step)})); '
          'do ${_dump(body)}; done',
    CondCommand(:final expr) => '[[ ${_cond(expr)} ]]',
  };
  return [body, ...command.redirects.map(_redirect)].join(' ');
}

/// Присваивание в слепке: скаляр, элемент и литерал массива, в том числе с `+=`.
String _assignment(Assignment assignment) {
  final op = assignment.append ? '+=' : '=';
  final index = assignment.index;
  final head = index == null
      ? assignment.name
      : '${assignment.name}[${_word(index)}]';
  final elements = assignment.elements;
  if (elements == null) return '$head$op${_word(assignment.value)}';
  final body = elements
      .map((element) {
        final key = element.key;
        final value = _word(element.value);
        return key == null ? value : '[${_word(key)}]=$value';
      })
      .join(' ');
  return '$head$op($body)';
}

String _if(List<ConditionalBranch> branches, ScriptNode? elseBody) {
  final buffer = StringBuffer();
  for (var i = 0; i < branches.length; i++) {
    final branch = branches[i];
    final keyword = i == 0 ? 'if' : 'elif';
    buffer.write(
      '$keyword ${_dump(branch.condition)}; then ${_dump(branch.body)}; ',
    );
  }
  if (elseBody != null) buffer.write('else ${_dump(elseBody)}; ');
  buffer.write('fi');
  return buffer.toString();
}

/// Ветка `case`: пустое тело не даёт лишнего пробела, терминатор печатается как в исходнике.
String _clause(CaseClause clause) {
  final patterns = clause.patterns.map(_word).join('|');
  final body = _dump(clause.body);
  final terminator = switch (clause.terminator) {
    CaseTerminator.stop => ';;',
    CaseTerminator.fallthrough => ';&',
    CaseTerminator.testNext => ';;&',
  };
  return '$patterns) ${body.isEmpty ? '' : '$body '}$terminator';
}

String _redirect(Redirect redirect) => switch (redirect) {
  FileRedirect(:final fd, :final kind, :final target) => switch (kind) {
    RedirectKind.input => '$fd<${_word(target)}',
    RedirectKind.output => '${fd == 1 ? '' : fd}>${_word(target)}',
    RedirectKind.append => '${fd == 1 ? '' : fd}>>${_word(target)}',
    RedirectKind.hereString => '<<<${_word(target)}',
    RedirectKind.dupOutput => '$fd>&${_raw(target)}',
  },
  HeredocRedirect(:final fd, :final body, :final terminated) =>
    '$fd<<${_word(body)}${terminated ? '' : '(unterminated)'}',
};

/// [inDq] — слово внутри двойных кавычек: литералы там показываются как есть.
/// Вне кавычек литерал в кавычках (например тело здесь-документа) печатается в `'...'`, чтобы его не спутать с переменной.
String _word(ShellWord word, {bool inDq = false}) =>
    word.parts.map((p) => _part(p, inDq: inDq)).join();

String _raw(ShellWord word) =>
    word.parts.map((p) => (p as LiteralPart).text).join();

String _part(WordPart part, {required bool inDq}) => switch (part) {
  LiteralPart(:final text, :final quoted) => quoted && !inDq ? "'$text'" : text,
  TildePart() => '~',
  ParamPart p => _param(p),
  BadSubstitutionPart(:final text) => '\${$text}',
  CommandPart(:final script) => '\$(${_dump(script)})',
  // Арифметическое выражение разбирается как двойные кавычки: литералы там без кавычек.
  ArithmeticPart(:final expression) => '\$((${_word(expression, inDq: true)}))',
  QuotedPart(:final parts) =>
    '"${parts.map((p) => _part(p, inDq: true)).join()}"',
};

/// Слепок параметра: `$NAME` для простого случая, иначе `${...}` с видом, индексом и модификатором.
String _param(ParamPart part) {
  if (part.kind == ParamKind.names) {
    final star = (part.subscript as AllElements).star;
    return '\${!${part.name}${star ? '*' : '@'}}';
  }
  final sub = switch (part.subscript) {
    null => '',
    AllElements(:final star) => star ? '[*]' : '[@]',
    IndexElement(:final source) => '[$source]',
  };
  final kind = switch (part.kind) {
    ParamKind.length => '#',
    ParamKind.indirect || ParamKind.keys => '!',
    _ => '',
  };
  final op = part.op == null ? '' : _op(part.op!);
  if (kind.isEmpty && sub.isEmpty && op.isEmpty) return '\$${part.name}';
  return '\${$kind${part.name}$sub$op}';
}

/// Слепок модификатора: его знак и операнды, как они записаны в исходнике.
String _op(ParamOp op) => switch (op) {
  ParamDefaultOp(:final kind, :final word, :final nullIsUnset) =>
    '${nullIsUnset ? ':' : ''}${_defaultSign(kind)}${_operand(word)}',
  ParamTrimOp(:final prefix, :final longest, :final pattern) =>
    _trimSign(prefix, longest) + _operand(pattern),
  ParamReplaceOp(:final mode, :final pattern, :final replacement) =>
    '${_replaceSign(mode)}${_operand(pattern)}/${_operand(replacement)}',
  ParamSliceOp(:final offset, :final length) =>
    ':${_operand(offset)}${length == null ? '' : ':${_operand(length)}'}',
  ParamCaseOp(:final mode, :final pattern) =>
    _caseSign(mode) + (pattern == null ? '' : _operand(pattern)),
  ParamTransformOp(:final letter) => '@$letter',
};

/// Операнд модификатора печатается так, как записан в исходнике: без кавычек вокруг простых частей.
String _operand(ShellWord word) => _word(word, inDq: true);

String _defaultSign(ParamDefaultKind kind) => switch (kind) {
  ParamDefaultKind.useDefault => '-',
  ParamDefaultKind.assign => '=',
  ParamDefaultKind.error => '?',
  ParamDefaultKind.alternative => '+',
};

String _trimSign(bool prefix, bool longest) {
  final sign = prefix ? '#' : '%';
  return longest ? sign * 2 : sign;
}

String _replaceSign(ReplaceMode mode) => switch (mode) {
  ReplaceMode.first => '/',
  ReplaceMode.all => '//',
  ReplaceMode.prefix => '/#',
  ReplaceMode.suffix => '/%',
};

String _caseSign(ParamCaseMode mode) => switch (mode) {
  ParamCaseMode.upperFirst => '^',
  ParamCaseMode.upperAll => '^^',
  ParamCaseMode.lowerFirst => ',',
  ParamCaseMode.lowerAll => ',,',
  ParamCaseMode.toggleFirst => '~',
  ParamCaseMode.toggleAll => '~~',
};

/// Возвращает текст ошибки разбора или null, если скрипт разобран.
ShellSyntaxException? _error(String script) {
  try {
    ShellParser.parse(script);
    return null;
  } on ShellSyntaxException catch (e) {
    return e;
  }
}

void main() {
  group('дерево разбора (golden)', () {
    final goldens = <String, String>{
      'echo hello world': 'echo hello world',
      'ls -la /tmp | grep x && echo ok || echo fail':
          'ls -la /tmp | grep x && echo ok || echo fail',
      "echo 'a b' \"c \$HOME\" d\\ e": "echo 'a b' \"c \$HOME\" d' 'e",
      'x=1 y=two cmd': 'x=1 y=two cmd',
      'cd ~/src': 'cd ~/src',
      'PATH=/bin:~/bin cmd': 'PATH=/bin:~/bin cmd',
      r'echo $(date +%F)': r'echo $(date +%F)',
      'grep -e foo 2>/dev/null; echo \$?': 'grep -e foo 2>/dev/null; echo \$?',
      'cat > out.txt < in.txt': 'cat >out.txt 0<in.txt',
      'make 2>&1 | tee log': 'make 2>&1 | tee log',
      '! false': '! false',
      'echo a\necho b': 'echo a; echo b',
      'echo "x\$(echo "y")"': 'echo "x\$(echo "y")"',
      'echo `date`': 'echo \$(date)',
      r'echo $((1+2))': r'echo $((1+2))',
      r'echo "$((1 + 2))"': r'echo "$((1 + 2))"',
      'if true; then echo y; fi': 'if true; then echo y; fi',
      'if false; then a; elif true; then b; else c; fi':
          'if false; then a; elif true; then b; else c; fi',
      'for i in 1 2; do echo \$i; done': 'for i in 1 2; do echo \$i; done',
      'select x in a b; do echo \$x; done':
          'select x in a b; do echo \$x; done',
      'for i; do echo \$i; done': 'for i; do echo \$i; done',
      'while read x; do echo \$x; done < in.txt':
          'while read x; do echo \$x; done 0<in.txt',
      'until false; do :; done': 'until false; do :; done',
      '(echo sub)': '(echo sub)',
      '{ echo a; }': '{ echo a; }',
      'f() { echo \$1; }': 'f() { echo \$1; }',
      'function g { echo x; }': 'g() { echo x; }',
      'case \$v in a|b) echo ab;; *) echo other;; esac':
          'case \$v in a|b) echo ab ;; *) echo other ;; esac',
      'case x in x) ;; esac': 'case x in x) ;; esac',
      r'echo ${x:-d} ${x=e} ${x?f} ${x+g}':
          r'echo ${x:-d} ${x=e} ${x?f} ${x+g}',
      r'echo ${#x} ${#@} ${#a[@]}': r'echo ${#x} ${#@} ${#a[@]}',
      r'echo ${x#*/} ${x##a} ${x%.*} ${x%%b}':
          r'echo ${x#*/} ${x##a} ${x%.*} ${x%%b}',
      r'echo ${x/a/b} ${x//a/} ${x/#a/b} ${x/%a/b}':
          r'echo ${x/a/b} ${x//a/} ${x/#a/b} ${x/%a/b}',
      r'echo ${x:1} ${x:1:2} ${x:(-2)}': r'echo ${x:1} ${x:1:2} ${x:(-2)}',
      r'echo ${x^} ${x^^} ${x,} ${x,,} ${x~}':
          r'echo ${x^} ${x^^} ${x,} ${x,,} ${x~}',
      r'echo ${x@Q} ${x@E} ${x@U} ${x@u} ${x@L} ${x@l}':
          r'echo ${x@Q} ${x@E} ${x@U} ${x@u} ${x@L} ${x@l}',
      r'echo ${!a*} ${!a@} ${!a[@]} ${!a[*]} ${!#}':
          r'echo ${!a*} ${!a@} ${!a[@]} ${!a[*]} ${!#}',
      r'echo ${1} ${10} ${@} ${*} ${#} ${?}': r'echo $1 $10 $@ $* $# $?',
      'case x in a) echo a;& b) echo b;;& c) echo c;; esac':
          'case x in a) echo a ;& b) echo b ;;& c) echo c ;; esac',
    };
    for (final MapEntry(:key, :value) in goldens.entries) {
      test('«$key»', () {
        expect(_dump(ShellParser.parse(key)), value);
      });
    }

    test('здесь-документ с расширениями и без', () {
      expect(
        _dump(ShellParser.parse('cat <<EOF\nhi \$USER\nEOF\n')),
        "cat 0<<'hi '\$USER'\n'",
      );
      expect(
        _dump(ShellParser.parse("cat <<'EOF'\n\$x\nEOF\n")),
        "cat 0<<'\$x\n'",
      );
      expect(
        _dump(ShellParser.parse('cat <<-EOF\n\tindented\n\tEOF\n')),
        "cat 0<<'indented\n'",
      );
    });

    test('незакрытый здесь-документ читается до конца скрипта', () {
      expect(
        _dump(ShellParser.parse('cat <<EOF\nline')),
        "cat 0<<'line\n'(unterminated)",
      );
    });
  });

  group('согласованность с bash -n', () {
    /// Конструкции, которые bash принимает и которые поддерживаются целиком.
    const supported = [
      'echo hi',
      'echo "\$HOME" \'\$HOME\'',
      'echo a | wc -l',
      'true && echo yes || echo no',
      r'x=1; echo $x',
      r'echo $(echo $(echo deep))',
      'cat <<EOF\nbody\nEOF',
      'echo ~',
      'printf "%s\\n" a b',
      'ls /nonexistent 2>&1 | head -1',
      'echo "unterminated \\" quote in double"',
      'echo a\\\nb',
      'echo hi # comment',
      'cmd >out 2>>err <in',
      'echo `date`',
      r'echo $((1+2))',
      'if true; then echo y; fi',
      'if false; then a; elif true; then b; else c; fi',
      'for i in 1 2; do echo \$i; done',
      'select x in a b; do echo \$x; done',
      'for i; do echo \$i; done',
      'while false; do :; done',
      'until true; do :; done',
      '(echo sub)',
      '{ echo a; }',
      'f() { echo \$1; }',
      'function g { echo x; }',
      'case x in x) echo;; esac',
      'case x in a) echo a;& b) echo b;;& c) echo c;; esac',
      'while read x; do echo \$x; done < in.txt',
      r'echo ${x:-default}',
      r'echo ${#x} ${x#p} ${x//a/b} ${x:1:2} ${x^^} ${!p*} ${a[@]} ${a[*]} ${x@Q}',
      r'echo ${x[1]} ${x[@]:1} ${!x} ${x:+"a b"} ${x/#a/b}',
      '((i++))',
      'for ((i=0; i<2; i++)); do echo \$i; done',
      'x=(a b); x+=(c); x[1]=z',
      '[[ -f in.txt ]]',
      '[[ abc == a* && -n abc ]]',
      r'[[ $x =~ ^a ]]',
    ];

    /// Конструкции, которые bash отвергает. Наш разбор обязан отвергнуть их тоже, и не как «unsupported».
    const syntaxErrors = [
      '| echo',
      'echo a &&',
      'echo a ;;',
      'echo (',
      'echo )',
      '; echo',
      'echo "unterminated',
      "echo 'open",
      'echo \$(',
      '>',
      'if true; then echo a',
      'for i in 1 2; echo \$i; done',
      'case x in x) echo;;',
    ];

    /// Конструкции, которые bash принимает, а виртуальный shell пока нет. Ошибка обязана быть
    /// «unsupported»: модель увидит явный отказ, а не молчаливое отличие.
    const unsupportedButValid = [
      'echo a & echo b',
      'echo ~+',
      r'echo ${x@A}',
      'time ls',
    ];

    final bashAvailable = !Platform.isWindows;

    for (final script in supported) {
      test('поддерживается и bash: ${script.replaceAll('\n', r'\n')}', () {
        if (bashAvailable) {
          expect(Process.runSync('bash', ['-n', '-c', script]).exitCode, 0);
        }
        expect(_error(script), isNull);
      });
    }

    for (final script in syntaxErrors) {
      test('синтаксическая ошибка и в bash, и здесь: $script', () {
        if (bashAvailable) {
          expect(
            Process.runSync('bash', ['-n', '-c', script]).exitCode,
            isNot(0),
          );
        }
        final error = _error(script);
        expect(error, isNotNull);
        expect(error!.unsupported, isFalse, reason: error.message);
      });
    }

    for (final script in unsupportedButValid) {
      test('bash принимает, виртуальный shell отказывает явно: $script', () {
        if (bashAvailable) {
          expect(Process.runSync('bash', ['-n', '-c', script]).exitCode, 0);
        }
        final error = _error(script);
        expect(error, isNotNull);
        expect(error!.unsupported, isTrue, reason: error.message);
      });
    }
  });

  group('сообщения', () {
    test('синтаксическая ошибка оформлена как в bash', () {
      final error = _error('echo a |');
      expect(
        error?.text,
        'bash: -c: line 1: syntax error: unexpected end of file',
      );
    });

    test('неподдерживаемая конструкция называет её', () {
      final error = _error('echo a & echo b');
      expect(error?.text, 'bash: -c: line 1: unsupported syntax: operator &');
    });

    test('слишком глубокая вложенность — это лимит, а не синтаксис', () {
      // Скрипт допустим для bash, но превышает лимит глубины: это ресурсное ограничение, поэтому
      // ошибка не должна выглядеть как синтаксическая.
      final deep = '${'{ ' * 40}echo x${'; }' * 40}';
      expect(
        () => ShellParser.parse(deep),
        throwsA(
          isA<ShellLimitExceeded>().having(
            (e) => e.message,
            'message',
            contains('nested'),
          ),
        ),
      );
    });

    test('номер строки указывает на место ошибки', () {
      final error = _error('echo a\necho b\n| x');
      expect(error?.line, 3);
    });
  });
}
