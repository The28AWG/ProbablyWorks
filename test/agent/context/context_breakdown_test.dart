import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/context/context_breakdown.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

void main() {
  test('splits system, conversation, tool results, files and tools', () {
    final breakdown = ContextBreakdown.of(
      [
        const LlmMessage.system('system'),
        const LlmMessage.user('hello'),
        const LlmMessage(
          role: LlmRole.assistant,
          content: 'answer',
          toolCalls: [LlmToolCall(id: 'c', name: 'read_file', arguments: '{}')],
        ),
        const LlmMessage(role: LlmRole.tool, content: 'tool output'),
        LlmMessage(
          role: LlmRole.user,
          content: 'file',
          files: [
            LlmFilePart(
              name: 'a.png',
              mimeType: 'image/png',
              bytes: Uint8List(10),
            ),
          ],
        ),
      ],
      tools: const [
        LlmToolSpec(
          name: 'read_file',
          description: 'read',
          parameters: {'type': 'object'},
        ),
      ],
    );

    expect(breakdown.systemChars, 6);
    expect(breakdown.historyChars, greaterThan(6));
    expect(breakdown.toolResultChars, 11);
    expect(breakdown.attachmentBytes, 10);
    expect(breakdown.toolSchemaChars, greaterThan(0));
    expect(breakdown.totalChars, greaterThan(0));
    // Всё в примере — ASCII, поэтому байты текста совпадают с символами,
    // а вес запроса превышает их только на вложения.
    expect(breakdown.textBytes, breakdown.totalTextChars);
    expect(breakdown.requestBytes, breakdown.totalTextChars + 10);
  });

  test('counts UTF-8 bytes separately from characters', () {
    final breakdown = ContextBreakdown.of([const LlmMessage.user('你好 🙂')]);

    // Пять UTF-16 единиц: три иероглифа и суррогатная пара эмодзи.
    expect(breakdown.historyChars, 5);
    // Байты: 3 + 3 + 1 (пробел) + 4.
    expect(breakdown.textBytes, 11);
    expect(breakdown.requestBytes, 11);
    expect(breakdown.requestKilobytes, closeTo(11 / 1024, 1e-9));
  });

  test('falls back to characters when bytes were not measured', () {
    const breakdown = ContextBreakdown(systemChars: 100, attachmentBytes: 2048);

    // Разбивка собрана вручную: [ContextBreakdown.textBytes] равен нулю, и
    // допущение «символ = байт» даёт нижнюю оценку вместо нуля.
    expect(breakdown.requestBytes, 2148);
    expect(breakdown.requestKilobytes, closeTo(2148 / 1024, 1e-9));
  });

  test('token estimate uses bytes for non-ASCII text', () {
    // «привет» — 6 символов и 12 байт UTF-8: оценка по байтам даёт 3 токена,
    // по символам было бы 2.
    final breakdown = ContextBreakdown.of([const LlmMessage.user('привет')]);

    expect(breakdown.historyChars, 6);
    expect(breakdown.historyBytes, 12);
    expect(breakdown.historyTokens, 3);
  });
}
