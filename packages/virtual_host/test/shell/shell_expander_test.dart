import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_host/src/in_memory_vfs_store.dart';
import 'package:virtual_host/src/shell/shell_ast.dart';
import 'package:virtual_host/src/shell/shell_errors.dart';
import 'package:virtual_host/src/shell/shell_expander.dart';
import 'package:virtual_host/src/shell/shell_state.dart';
import 'package:virtual_host/src/shell/shell_word_parser.dart';
import 'package:virtual_host/src/virtual_fs.dart';
import 'package:virtual_host/src/virtual_limits.dart';
import 'package:virtual_host/src/virtual_profile.dart';

/// Состояние, которое задаёт тест. По умолчанию — как при старте оболочки.
ShellState _state([void Function(ShellState state)? setup]) {
  final state = ShellState.initial(
    const VirtualProfile(home: '/work'),
    '/work',
  );
  setup?.call(state);
  return state;
}

/// Расширитель над [state] без реальной ФС: подстановок команд в этих тестах нет.
ShellExpander _expander(ShellState state) => ShellExpander(
  state: state,
  fs: VirtualFs(
    InMemoryVfsStore(),
    limits: const VirtualLimits(),
    clock: () => 1700000000,
  ),
  home: '/work',
  substitute: (_) async => (Uint8List(0), 0),
);

/// Слово в том виде, как его получает расширитель после разбора команды.
ShellWord _parse(String word) =>
    ShellWordParser(depth: 0, limits: const VirtualLimits()).parse(word);

/// Поля, которые получит команда от [word] в состоянии, заданном [setup].
Future<List<String>> _fields(
  String word, {
  void Function(ShellState state)? setup,
}) {
  final state = _state(setup);
  return _expander(state).fields(_parse(word));
}

/// Ожидаемая ошибка раскрытия: текст без префикса `bash: line N:` и код выхода.
Matcher _paramError(String message, int exitCode) => throwsA(
  isA<ShellParamError>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.exitCode, 'exitCode', exitCode),
);

void main() {
  group('nounset (set -u)', () {
    void nounset(ShellState state) {
      state.options.add('nounset');
    }

    test('неустановленная переменная — ошибка с кодом 127', () async {
      await expectLater(
        _fields(r'${y}', setup: nounset),
        _paramError('y: unbound variable', 127),
      );
    });

    test('позиционный параметр называется как в bash', () async {
      await expectLater(
        _fields(r'$1', setup: nounset),
        _paramError(r'$1: unbound variable', 127),
      );
    });

    test('`\${#x}` и `\${x%y}` тоже требуют заданной переменной', () async {
      await expectLater(
        _fields(r'${#zz}', setup: nounset),
        _paramError('zz: unbound variable', 127),
      );
      await expectLater(
        _fields(r'${zz%x}', setup: nounset),
        _paramError('zz: unbound variable', 127),
      );
    });

    test('значения по умолчанию и проверки заданности не ошибаются', () async {
      expect(await _fields(r'${y:-d}', setup: nounset), ['d']);
      expect(await _fields(r'${y-e}', setup: nounset), ['e']);
      expect(await _fields(r'${y:+f}', setup: nounset), isEmpty);
    });

    test(
      'аргумент значения по умолчанию раскрывается, только если нужен',
      () async {
        await expectLater(
          _fields(r'${zz:-$yy}', setup: nounset),
          _paramError('yy: unbound variable', 127),
        );
      },
    );

    test(
      '`"\$@"` без аргументов пуст, `"\$*"` даёт одно пустое поле',
      () async {
        expect(await _fields(r'"$@"', setup: nounset), isEmpty);
        expect(await _fields(r'"$*"', setup: nounset), ['']);
        expect(await _fields(r'$#', setup: nounset), ['0']);
      },
    );

    test('элемент пустого массива и несуществующий индекс — ошибка', () async {
      await expectLater(
        _fields(
          '\${a[3]}',
          setup: (s) {
            nounset(s);
            s.setArray('a', ['x']);
          },
        ),
        _paramError('a[3]: unbound variable', 127),
      );
    });

    test('`\${x:=v}` задаёт переменную и при nounset', () async {
      final state = _state(nounset);
      expect(await _expander(state).fields(_parse(r'${zz:=q}')), ['q']);
      expect(state.get('zz'), 'q');
    });

    test('`set +u` снова разрешает неустановленные переменные', () async {
      expect(
        await _fields(
          r'"$zz"',
          setup: (s) {
            nounset(s);
            s.options.remove('nounset');
          },
        ),
        [''],
      );
    });

    test(
      'косвенность неустановленной переменной — ошибка и без nounset',
      () async {
        await expectLater(
          _fields(r'${!zz}'),
          _paramError('zz: invalid indirect expansion', 1),
        );
      },
    );
  });

  group('позиционные параметры', () {
    void args(ShellState state) {
      state.positional = ['a', 'b', 'c', 'd'];
    }

    test('срезы `\${@:off:len}` и `\${*:off}`', () async {
      expect(await _fields(r'${@:2:2}', setup: args), ['b', 'c']);
      expect(await _fields(r'${@: -2}', setup: args), ['c', 'd']);
      expect(await _fields(r'${@:4:5}', setup: args), ['d']);
      expect(await _fields(r'${*:3}', setup: args), ['c', 'd']);
    });

    test('`\${@:0:1}` начинается с имени оболочки', () async {
      expect(await _fields(r'${@:0:1}', setup: args), ['bash']);
    });

    test('`"\${*:off}"` склеивает поля через IFS', () async {
      expect(await _fields(r'"${*:3}"', setup: args), ['c d']);
    });

    test('`\${#@}` и `\${#*}` — число аргументов', () async {
      expect(await _fields(r'${#@}', setup: args), ['4']);
      expect(await _fields(r'${#*}', setup: args), ['4']);
    });

    test('`\${@:-x}` без аргументов даёт значение по умолчанию', () async {
      expect(await _fields(r'"${@:-x}"'), ['x']);
    });

    test('`\${1:=v}` с аргументом не присваивает и не падает', () async {
      expect(await _fields(r'${1:=v}', setup: args), ['a']);
    });
  });

  group('массивы', () {
    void arr(ShellState state) {
      state.setArray('a', ['one', 'two', 'three']);
    }

    test('`"\${a[@]}"` даёт отдельные поля, `\${a[@]}` тоже', () async {
      expect(await _fields(r'"${a[@]}"', setup: arr), ['one', 'two', 'three']);
      expect(await _fields(r'${a[@]}', setup: arr), ['one', 'two', 'three']);
    });

    test('`"\${a[*]}"` склеивает элементы первым символом IFS', () async {
      expect(await _fields(r'"${a[*]}"', setup: arr), ['one two three']);
      expect(
        await _fields(
          r'"${a[*]}"',
          setup: (s) {
            arr(s);
            s.set('IFS', ':');
          },
        ),
        ['one:two:three'],
      );
    });

    test('`\$a` и `\${a}` — элемент 0', () async {
      expect(await _fields(r'$a', setup: arr), ['one']);
      expect(await _fields(r'${a}', setup: arr), ['one']);
    });

    test('индексы: положительный и отрицательный', () async {
      expect(await _fields(r'${a[1]}', setup: arr), ['two']);
      expect(await _fields(r'${a[-1]}', setup: arr), ['three']);
    });

    test('длины: массив, элемент и `\${#a}` — элемент 0', () async {
      expect(await _fields(r'${#a[@]}', setup: arr), ['3']);
      expect(await _fields(r'${#a[1]}', setup: arr), ['3']);
      expect(await _fields(r'${#a}', setup: arr), ['3']);
    });

    test('ключи `\${!a[@]}` и `"\${!a[*]}"`', () async {
      expect(await _fields(r'${!a[@]}', setup: arr), ['0', '1', '2']);
      expect(await _fields(r'"${!a[*]}"', setup: arr), ['0 1 2']);
    });

    test('срезы элементов по индексу и `\${a[*]:off:len}`', () async {
      expect(await _fields(r'${a[@]:1}', setup: arr), ['two', 'three']);
      expect(await _fields(r'${a[@]:1:1}', setup: arr), ['two']);
      expect(await _fields(r'${a[@]: -1}', setup: arr), ['three']);
      expect(await _fields(r'${a[*]:0:2}', setup: arr), ['one', 'two']);
    });

    test('модификаторы применяются к каждому элементу', () async {
      expect(await _fields(r'"${a[@]^^}"', setup: arr), [
        'ONE',
        'TWO',
        'THREE',
      ]);
      expect(await _fields(r'"${a[@]/o/0}"', setup: arr), [
        '0ne',
        'tw0',
        'three',
      ]);
    });

    test(
      '`\${a[5]:=k}` добавляет индекс, остальные элементы сохраняются',
      () async {
        final state = _state(arr);
        expect(await _expander(state).fields(_parse(r'${a[5]:=k}')), ['k']);
        expect(await _expander(state).fields(_parse(r'"${a[@]}"')), [
          'one',
          'two',
          'three',
          'k',
        ]);
      },
    );

    test(
      'пустой массив: `"\${e[@]}"` пуст, `"\${e[*]}"` — одно пустое поле',
      () async {
        void empty(ShellState s) => s.setArray('e', []);
        expect(await _fields(r'"${e[@]}"', setup: empty), isEmpty);
        expect(await _fields(r'"${e[*]}"', setup: empty), ['']);
        expect(await _fields(r'"${e[@]:-d}"', setup: empty), ['d']);
        expect(await _fields(r'"${e[@]+alt}"', setup: empty), isEmpty);
      },
    );

    test('пустой элемент сохраняется в кавычках', () async {
      void blank(ShellState s) => s.setArray('z', ['']);
      expect(await _fields(r'"${z[@]-x}"', setup: blank), ['']);
      expect(await _fields(r'"${z[*]-x}"', setup: blank), ['']);
      expect(await _fields(r'"${z[@]:+alt}"', setup: blank), ['']);
      expect(await _fields(r'"${z[@]+alt}"', setup: blank), ['alt']);
      expect(await _fields(r'${#z[@]}', setup: blank), ['1']);
    });
  });

  group('readonly', () {
    test('`\${r:=v}` для readonly бросает ShellReadonlyError', () async {
      final state = _state((s) => s.declare('r', {VarAttr.readonly}));
      await expectLater(
        _expander(state).fields(_parse(r'${r:=v}')),
        throwsA(isA<ShellReadonlyError>().having((e) => e.name, 'name', 'r')),
      );
    });

    test('`\${r:-v}` без присваивания не трогает readonly', () async {
      expect(
        await _fields(
          r'${r:-v}',
          setup: (s) => s.declare('r', {VarAttr.readonly}),
        ),
        ['v'],
      );
    });
  });
}
