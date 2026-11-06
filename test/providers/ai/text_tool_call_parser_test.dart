import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/text_tool_call_parser.dart';

const _tools = [
  LlmToolSpec(
    name: 'run_command',
    description: '',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
        'background': {'type': 'boolean'},
      },
      'required': ['command'],
    },
  ),
  LlmToolSpec(
    name: 'read_file',
    description: '',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'offset': {
          'anyOf': [
            {'type': 'integer'},
            {'type': 'null'},
          ],
        },
      },
      'required': ['path'],
    },
  ),
  LlmToolSpec(
    name: 'write_file',
    description: '',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
    },
  ),
  LlmToolSpec(
    name: 'set_location',
    description: '',
    parameters: {
      'type': 'object',
      'properties': {
        'location': {r'$ref': r'#/$defs/Location'},
      },
      r'$defs': {
        'Location': {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
        },
      },
    },
  ),
];

/// Прогоняет куски так же, как поток OpenRouter: текст наружу, вызовы в сторону.
({String text, List<LlmToolCall> calls}) _run(
  List<String> chunks, [
  List<LlmToolSpec> tools = _tools,
]) {
  final parser = TextToolCallParser(tools);
  final text = StringBuffer();
  for (final chunk in chunks) {
    for (final event in parser.add(chunk)) {
      text.write(event.text);
    }
  }
  for (final event in parser.flush()) {
    text.write(event.text);
  }
  return (text: text.toString(), calls: parser.calls);
}

Map<String, dynamic> _args(LlmToolCall call) =>
    jsonDecode(call.arguments) as Map<String, dynamic>;

void main() {
  test('dots invoke blocks become run_command calls and leave the text', () {
    const raw = '''
<dots_function_call>
<invoke name="run_command">
<parameter name="command">
ls -la /home/agent && echo "---ROOT---" && ls -la / && echo "---TMP---" && ls -la /tmp
</parameter>
</invoke>
</dots_function_call>
<dots_function_call>
<invoke name="run_command">
<parameter name="command">
ls /usr/bin /bin /usr/local/bin 2>/dev/null | sort -u | head -80
</parameter>
</invoke>
</dots_function_call>''';

    final result = _run([raw]);

    expect(result.text, '\n');
    expect(result.calls, hasLength(2));
    expect(result.calls.first.id, 'text_0');
    expect(result.calls.first.name, 'run_command');
    expect(
      _args(result.calls.first)['command'],
      'ls -la /home/agent && echo "---ROOT---" && ls -la / && echo "---TMP---" && ls -la /tmp',
    );
    expect(
      _args(result.calls[1])['command'],
      'ls /usr/bin /bin /usr/local/bin 2>/dev/null | sort -u | head -80',
    );
  });

  test('a dots block split per character does not leak markup', () {
    const raw =
        '<dots_function_call><invoke name="run_command">'
        '<parameter name="command">ls</parameter></invoke></dots_function_call>';
    final result = _run(raw.characters.toList());

    expect(result.text, isEmpty);
    expect(result.calls.single.name, 'run_command');
    expect(_args(result.calls.single)['command'], 'ls');
  });

  test('dots json fallback and several invokes in one block', () {
    const raw =
        '<dots_function_call>{"name":"run_command","arguments":{"command":"pwd"}}'
        '</dots_function_call>'
        '<dots_function_call>'
        '<invoke name="read_file"><parameter name="path">a.txt</parameter>'
        '<parameter name="offset">12</parameter></invoke>'
        '<invoke name="run_command"><parameter name="command">ls</parameter></invoke>'
        '</dots_function_call>';
    final result = _run([raw]);

    expect(result.text, isEmpty);
    expect(_args(result.calls.first)['command'], 'pwd');
    expect(_args(result.calls[1]), {'path': 'a.txt', 'offset': 12});
    expect(_args(result.calls[2])['command'], 'ls');
  });

  test('xml values follow the tool schema, including ref and anyOf', () {
    const raw = '''
<dots_function_call>
<invoke name="set_location">
<parameter name="location" string="false">
{"city": "Shanghai"}
</parameter>
</invoke>
</dots_function_call>''';
    final result = _run([raw]);

    expect(_args(result.calls.single)['location'], {'city': 'Shanghai'});
  });

  test('hermes json inside tool_call accepts a string of arguments', () {
    const raw =
        '<tool_call>\n'
        '{"name": "run_command", "arguments": "{\\"command\\": \\"ls\\"}"}\n'
        '</tool_call>';
    final result = _run([raw]);

    expect(result.text, isEmpty);
    expect(_args(result.calls.single), {'command': 'ls'});
  });

  test('qwen coder xml keeps inner newlines and coerces bool', () {
    const raw = '''
Посмотрю.
<tool_call>
<function=write_file>
<parameter=path>
a.txt
</parameter>
<parameter=content>
line1
line2
</parameter>
</function>
<function=run_command>
<parameter=command>
ls
</parameter>
<parameter=background>
true
</parameter>
</function>
</tool_call>
Готово.''';
    final result = _run([raw]);

    expect(result.text, 'Посмотрю.\n\nГотово.');
    expect(_args(result.calls.first), {
      'path': 'a.txt',
      'content': 'line1\nline2',
    });
    expect(_args(result.calls[1]), {'command': 'ls', 'background': true});
  });

  test('glm arg_key pairs and a name-then-json tool_call', () {
    const glm =
        '<tool_call>read_file\n'
        '<arg_key>path</arg_key><arg_value>a.txt</arg_value>\n'
        '<arg_key>offset</arg_key><arg_value>3</arg_value>\n'
        '</tool_call>';
    const named = '<tool_call>\nrun_command\n{"command":"pwd"}\n</tool_call>';
    final result = _run([glm, named]);

    expect(result.text, isEmpty);
    expect(_args(result.calls.first), {'path': 'a.txt', 'offset': 3});
    expect(_args(result.calls[1]), {'command': 'pwd'});
  });

  test('minimax and function_calls use the invoke body', () {
    const raw =
        '<minimax:tool_call><invoke name=\'run_command\'>'
        '<parameter name="command">pwd</parameter></invoke></minimax:tool_call>'
        '<function_calls><invoke name="read_file">'
        '<parameter name="path">b.txt</parameter></invoke></function_calls>';
    final result = _run([raw]);

    expect(result.calls.map((call) => call.name), ['run_command', 'read_file']);
    expect(_args(result.calls[1])['path'], 'b.txt');
  });

  test('deepseek markers and a kimi section', () {
    const deepseek =
        '<\uFF5Ctool\u2581calls\u2581begin\uFF5C>'
        '<\uFF5Ctool\u2581call\u2581begin\uFF5C>function<\uFF5Ctool\u2581sep\uFF5C>run_command\n'
        '```json\n{"command":"ls"}\n```'
        '<\uFF5Ctool\u2581call\u2581end\uFF5C>'
        '<\uFF5Ctool\u2581calls\u2581end\uFF5C>';
    const kimi =
        '<|tool_calls_section_begin|>'
        '<|tool_call_begin|>functions.read_file:0<|tool_call_argument_begin|>'
        '{"path":"a.txt","offset":2}<|tool_call_end|>'
        '<|tool_calls_section_end|>';
    final result = _run([deepseek, kimi]);

    expect(result.text, isEmpty);
    expect(_args(result.calls.first), {'command': 'ls'});
    expect(_args(result.calls[1]), {'path': 'a.txt', 'offset': 2});
  });

  test('mistral array split across chunks', () {
    final result = _run([
      'ok[TOOL_CAL',
      'LS] [{"name":"run_command","arguments":{"command":"ls"}},{"name":"read_file","arguments":{"path":"a.txt"}}] tail',
    ]);

    expect(result.text, 'ok tail');
    expect(result.calls, hasLength(2));
    expect(_args(result.calls.first)['command'], 'ls');
  });

  test('llama function tag is a call only for a known tool', () {
    const known = '<function=run_command>{"command":"ls"}</function>';
    const unknown = '<function=explode>{"command":"ls"}</function>';
    final result = _run(['до $known между $unknown после']);

    expect(result.text, 'до  между $unknown после');
    expect(result.calls.single.name, 'run_command');
  });

  test('unknown tool markup and an unclosed block stay text', () {
    const unknown = '<tool_call>{"name":"explode","arguments":{}}</tool_call>';
    final unclosed = _run(['смотри <tool_call> дальше']);
    final foreign = _run([unknown]);
    final partial = _run(['хвост <dots_function_ca']);

    expect(unclosed.text, 'смотри <tool_call> дальше');
    expect(unclosed.calls, isEmpty);
    expect(foreign.text, unknown);
    expect(foreign.calls, isEmpty);
    expect(partial.text, 'хвост <dots_function_ca');
    expect(partial.calls, isEmpty);
  });

  test('without tools the markup is ordinary text', () {
    const raw =
        '<dots_function_call><invoke name="run_command">'
        '<parameter name="command">ls</parameter></invoke></dots_function_call>';
    final result = _run([raw], const []);

    expect(result.text, raw);
    expect(result.calls, isEmpty);
  });

  test('a cut tag prefix is not emitted until it is clearly not a tag', () {
    final result = _run(['Счёт <', 'b>']);

    expect(result.text, 'Счёт <b>');
    expect(result.calls, isEmpty);
  });

  test('merge drops a textual copy of a structured call', () {
    const structured = LlmToolCall(
      id: 'call_0',
      name: 'run_command',
      arguments: '{"command":"ls"}',
    );
    const same = LlmToolCall(
      id: 'text_0',
      name: 'run_command',
      arguments: '{"command":"ls"}',
    );
    const extra = LlmToolCall(
      id: 'text_1',
      name: 'read_file',
      arguments: '{"path":"a.txt"}',
    );

    expect(mergeToolCalls([structured], [same, extra]), [structured, extra]);
  });
}
