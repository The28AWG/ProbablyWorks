/// Печать дерева разбора обратно в текст оболочки.
///
/// Формат не совпадает с bash побайтно: пробелы и кавычки нормализуются. Напечатанный текст
/// должен снова разбираться и делать то же самое. Это нужно `declare -f` и `type`: модель читает
/// тело функции и может вставить его в новый скрипт.
library;

import 'package:virtual_host/src/shell/shell_ast.dart';

/// Печатает определение функции так, чтобы [ShellParser] собрал ту же команду.
String printFunction(FunctionDefinition function) {
  final body = function.body;
  final script = body is GroupCommand ? _script(body.body) : _command(body);
  return '${function.name} ()\n{\n$script\n}';
}

String _script(ScriptNode node) {
  if (node.lists.isEmpty) return ':';
  return node.lists.map(_list).join('\n');
}

String _list(AndOrList list) {
  final buffer = StringBuffer(_pipeline(list.pipelines.first));
  for (var i = 0; i < list.operators.length; i++) {
    final op = list.operators[i] == AndOrOperator.and ? ' && ' : ' || ';
    buffer
      ..write(op)
      ..write(_pipeline(list.pipelines[i + 1]));
  }
  return buffer.toString();
}

String _pipeline(Pipeline pipeline) {
  final parts = pipeline.commands.map(_command).join(' | ');
  return pipeline.negated ? '! $parts' : parts;
}

String _command(ShellCommand command) => switch (command) {
  SimpleCommand() => _simple(command),
  SubshellCommand() => _wrap(
    '(',
    _script(command.body),
    ')',
    command.redirects,
  ),
  GroupCommand() => _wrap('{', _script(command.body), '}', command.redirects),
  IfCommand() => _if(command),
  LoopCommand() => _loop(command),
  ForCommand() => _for(command),
  SelectCommand() => _select(command),
  CaseCommand() => _case(command),
  ArithmeticCommand() => _withRedirects(
    '(( ${_word(command.expression)} ))',
    command.redirects,
  ),
  ArithmeticFor() => _arithmeticFor(command),
  CondCommand() => _withRedirects(
    '[[ ${_cond(command.expr)} ]]',
    command.redirects,
  ),
  FunctionDefinition() => printFunction(command),
};

String _simple(SimpleCommand command) {
  final parts = <String>[
    for (final assignment in command.assignments) _assignment(assignment),
    for (final word in command.words) _word(word),
  ];
  return _withRedirects(parts.join(' '), command.redirects);
}

String _assignment(Assignment assignment) {
  final index = assignment.index;
  final elements = assignment.elements;
  final op = assignment.append ? '+=' : '=';
  final head = index == null
      ? assignment.name
      : '${assignment.name}[${_word(index)}]';
  if (elements != null) {
    final body = elements.map(_arrayElement).join(' ');
    return '$head$op($body)';
  }
  return '$head$op${_word(assignment.value)}';
}

String _arrayElement(ArrayElement element) {
  final key = element.key;
  final value = _word(element.value);
  return key == null ? value : '[${_word(key)}]=$value';
}

String _if(IfCommand command) {
  final buffer = StringBuffer();
  for (var i = 0; i < command.branches.length; i++) {
    final branch = command.branches[i];
    buffer
      ..write(i == 0 ? 'if ' : 'elif ')
      ..write(_script(branch.condition))
      ..write('; then\n')
      ..write(_script(branch.body));
    if (i != command.branches.length - 1 || command.elseBody != null) {
      buffer.write('\n');
    }
  }
  final elseBody = command.elseBody;
  if (elseBody != null) {
    buffer
      ..write('else\n')
      ..write(_script(elseBody));
  }
  buffer.write('\nfi');
  return _withRedirects(buffer.toString(), command.redirects);
}

String _loop(LoopCommand command) {
  final keyword = command.until ? 'until' : 'while';
  return _withRedirects(
    '$keyword ${_script(command.condition)}; do\n${_script(command.body)}\ndone',
    command.redirects,
  );
}

String _select(SelectCommand command) {
  final words = command.words;
  final head = words == null
      ? 'select ${command.variable}'
      : 'select ${command.variable} in ${words.map(_word).join(' ')}';
  return _withRedirects(
    '$head; do\n${_script(command.body)}\ndone',
    command.redirects,
  );
}

String _for(ForCommand command) {
  final words = command.words;
  final head = words == null
      ? 'for ${command.variable}'
      : 'for ${command.variable} in ${words.map(_word).join(' ')}';
  return _withRedirects(
    '$head; do\n${_script(command.body)}\ndone',
    command.redirects,
  );
}

String _arithmeticFor(ArithmeticFor command) {
  final init = command.init == null ? '' : _word(command.init!);
  final condition = command.condition == null ? '' : _word(command.condition!);
  final step = command.step == null ? '' : _word(command.step!);
  return _withRedirects(
    'for (($init; $condition; $step)); do\n${_script(command.body)}\ndone',
    command.redirects,
  );
}

String _case(CaseCommand command) {
  final buffer = StringBuffer('case ${_word(command.subject)} in\n');
  for (final clause in command.clauses) {
    buffer
      ..write(clause.patterns.map(_word).join(' | '))
      ..write(')\n')
      ..write(_script(clause.body))
      ..write('\n${_terminator(clause.terminator)}\n');
  }
  buffer.write('esac');
  return _withRedirects(buffer.toString(), command.redirects);
}

String _terminator(CaseTerminator terminator) => switch (terminator) {
  CaseTerminator.stop => ';;',
  CaseTerminator.fallthrough => ';&',
  CaseTerminator.testNext => ';;&',
};

String _cond(CondNode node) => switch (node) {
  CondOr() => '${_cond(node.left)} || ${_cond(node.right)}',
  CondAnd() => '${_cond(node.left)} && ${_cond(node.right)}',
  CondNot() => '! ${_cond(node.inner)}',
  CondGroup() => '( ${_cond(node.inner)} )',
  CondPrimary(:final op, :final left, :final right) => _condPrimary(
    op,
    left,
    right,
  ),
};

String _condPrimary(String? op, ShellWord? left, ShellWord? right) {
  if (op == null) return _word(right!);
  if (left == null) return '$op ${_word(right!)}';
  return '${_word(left)} $op ${_word(right!)}';
}

String _wrap(
  String open,
  String body,
  String close,
  List<Redirect> redirects,
) => _withRedirects('$open $body $close', redirects);

String _withRedirects(String text, List<Redirect> redirects) {
  if (redirects.isEmpty) return text;
  return '$text ${redirects.map(_redirect).join(' ')}';
}

String _redirect(Redirect redirect) => switch (redirect) {
  FileRedirect(:final fd, :final kind, :final target) =>
    '${_fd(fd, kind)}${_redirectOp(kind)} ${_word(target)}',
  HeredocRedirect(:final fd, :final delimiter, :final body) =>
    '${fd == 0 ? '' : fd}<<${_quote(delimiter)}\n${_word(body)}\n$delimiter',
};

String _fd(int fd, RedirectKind kind) {
  final standard = switch (kind) {
    RedirectKind.input || RedirectKind.hereString => 0,
    _ => 1,
  };
  return fd == standard ? '' : '$fd';
}

String _redirectOp(RedirectKind kind) => switch (kind) {
  RedirectKind.input => '<',
  RedirectKind.output => '>',
  RedirectKind.append => '>>',
  RedirectKind.hereString => '<<<',
  RedirectKind.dupOutput => '>&',
};

String _word(ShellWord word) {
  if (word.parts.isEmpty) return "''";
  if (word.parts.length == 1 && word.parts.first is QuotedPart) {
    final quoted = word.parts.first as QuotedPart;
    return '"${quoted.parts.map(_quotedPart).join()}"';
  }
  return word.parts.map(_part).join();
}

String _part(WordPart part) => switch (part) {
  LiteralPart(:final text, :final quoted) =>
    quoted ? _quote(text) : _bare(text),
  TildePart() => '~',
  ParamPart() => _param(part),
  BadSubstitutionPart(:final text) => '\${$text}',
  CommandPart(:final script) => '${r'$('}${_script(script)})',
  ArithmeticPart(:final expression) => '${r'$(('}${_word(expression)}))',
  QuotedPart(:final parts) => '"${parts.map(_quotedPart).join()}"',
};

/// Часть внутри двойных кавычек: параметры остаются параметрами, литералы экранируются.
String _quotedPart(WordPart part) => switch (part) {
  LiteralPart(:final text) => _escapeDouble(text),
  _ => _part(part),
};

String _param(ParamPart part) {
  if (part.kind == ParamKind.value &&
      part.subscript == null &&
      part.op == null &&
      _simpleName(part.name)) {
    return '\$${part.name}';
  }
  final buffer = StringBuffer('\${');
  switch (part.kind) {
    case ParamKind.length:
      buffer.write('#');
    case ParamKind.indirect:
      buffer.write('!');
    case ParamKind.keys:
      buffer.write('!');
    case ParamKind.names:
      buffer.write('!');
    case ParamKind.value:
      break;
  }
  buffer.write(part.name);
  if (part.kind == ParamKind.names) {
    final subscript = part.subscript;
    final star = subscript is AllElements && subscript.star;
    buffer.write(star ? '*' : '@');
  } else {
    final subscript = part.subscript;
    if (subscript != null) buffer.write(_subscript(subscript));
  }
  final op = part.op;
  if (op != null) buffer.write(_op(op));
  buffer.write('}');
  return buffer.toString();
}

bool _simpleName(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) ||
    RegExp(r'^[0-9]+$').hasMatch(name) ||
    '?#@*!-\$'.contains(name);

String _subscript(ParamSubscript subscript) => switch (subscript) {
  AllElements(:final star) => star ? '[*]' : '[@]',
  IndexElement(:final source) => '[$source]',
};

String _op(ParamOp op) => switch (op) {
  ParamDefaultOp(:final kind, :final word, :final nullIsUnset) =>
    '${nullIsUnset ? ':' : ''}${_defaultOp(kind)}${_word(word)}',
  ParamTrimOp(:final prefix, :final longest, :final pattern) =>
    '${prefix ? '#' : '%'}${longest ? (prefix ? '#' : '%') : ''}${_word(pattern)}',
  ParamReplaceOp(:final mode, :final pattern, :final replacement) =>
    '${_replaceMode(mode)}${_word(pattern)}/${_word(replacement)}',
  ParamSliceOp(:final offset, :final length) =>
    length == null ? ':${_word(offset)}' : ':${_word(offset)}:${_word(length)}',
  ParamCaseOp(:final mode, :final pattern) =>
    '${_caseMode(mode)}${pattern == null ? '' : _word(pattern)}',
  ParamTransformOp(:final letter) => '@$letter',
};

String _defaultOp(ParamDefaultKind kind) => switch (kind) {
  ParamDefaultKind.useDefault => '-',
  ParamDefaultKind.assign => '=',
  ParamDefaultKind.error => '?',
  ParamDefaultKind.alternative => '+',
};

String _replaceMode(ReplaceMode mode) => switch (mode) {
  ReplaceMode.first => '/',
  ReplaceMode.all => '//',
  ReplaceMode.prefix => '/#',
  ReplaceMode.suffix => '/%',
};

String _caseMode(ParamCaseMode mode) => switch (mode) {
  ParamCaseMode.upperFirst => '^',
  ParamCaseMode.upperAll => '^^',
  ParamCaseMode.lowerFirst => ',',
  ParamCaseMode.lowerAll => ',,',
  ParamCaseMode.toggleFirst => '~',
  ParamCaseMode.toggleAll => '~~',
};

String _bare(String text) {
  if (text.isEmpty) return "''";
  if (RegExp(r'''^[A-Za-z0-9_@%+=:,./-]+$''').hasMatch(text)) return text;
  return _quote(text);
}

String _quote(String text) => "'${text.replaceAll("'", r"'\''")}'";

String _escapeDouble(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll(r'$', r'\$')
    .replaceAll('`', r'\`');
