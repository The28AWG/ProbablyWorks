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
  });
}
