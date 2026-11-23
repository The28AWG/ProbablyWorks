import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:test/test.dart';

/// Живые проверки кэша OpenRouter на реальных запросах. Это не обычный прогон:
/// без `PW_LIVE_OPENROUTER=1` и ключа в `OPENROUTER_API_KEY` тесты пропускаются,
/// в CI и в `dart test` без переменных они ничего не отправляют и не стоят денег.
///
/// Зачем файл оставлен. Он был написан, чтобы ответить на три вопроса, которые
/// нельзя проверить юнит-тестами: попадает ли кэш префикса между шагами одного
/// хода; не ломает ли время в тексте сообщения кэш; принимает ли не-Anthropic
/// модель запрос с `cache_control`. Ответы записаны в `docs/agent/LLM_PROVIDERS.md`
/// (раздел «Кэширование префикса»). Повтора при сетевых ошибках намеренно нет:
/// это разовый замер, а не регрессионный набор. Если схема кэша поменяется или
/// провайдер перестанет кэшировать, файл можно запустить снова и сравнить
/// `LIVE_REPORT` с записанными результатами.
///
/// Запуск вручную из каталога пакета:
///   PW_LIVE_OPENROUTER=1 OPENROUTER_API_KEY=... dart test test/live/
///
/// Тест собирает запросы настоящим [ContextBuilder] и проверяет, что между
/// двумя шагами одного хода провайдер берёт префикс из кэша. Бюджет: 12 запросов
/// на кэш (3 пары) и 1 на другую модель; превышение — ошибка теста. Каждый тест
/// печатает строку `LIVE_REPORT [...]` с сырыми числами usage. Тесты проверяют
/// только, что запросы прошли; выводы о кэше делаются по отчёту.

/// Сколько пар «с меткой / контроль» запускать. Каждая пара — 2 схемы × 2 шага.
const _maxPairs = 3;

/// Модель с Anthropic-кэшем: без неё тест кэша ничего не покажет.
final _model =
    Platform.environment['PW_LIVE_MODEL'] ?? 'anthropic/claude-haiku-5.5';

/// Вторая модель: проверяем, что cache_control не ломает запрос.
final _otherModel =
    Platform.environment['PW_LIVE_OTHER_MODEL'] ??
    'deepseek/deepseek-v4.1-flash';

final _apiKey = Platform.environment['OPENROUTER_API_KEY'];
final _skip =
    Platform.environment['PW_LIVE_OPENROUTER'] == '1' &&
        (_apiKey?.isNotEmpty ?? false)
    ? null
    : 'задайте PW_LIVE_OPENROUTER=1 и OPENROUTER_API_KEY';

/// Счётчик запросов: при превышении тест падает, а не тратит деньги молча.
class _Budget {
  _Budget(this.max);

  final int max;
  int used = 0;

  void spend() {
    if (++used > max) {
      throw StateError('live budget exceeded: more than $max requests');
    }
  }
}

Host _host() => Host(
  id: 'h',
  name: 'host',
  kind: HostKind.local,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Chat _chat() => Chat(
  id: 'c',
  hostId: 'h',
  title: 'live cache check',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

ChatMessage _msg(
  String id,
  int seq,
  MessageRole role,
  DateTime createdAt, {
  String text = '',
  List<ToolCallRef> calls = const [],
  String? toolCallId,
}) => ChatMessage(
  id: id,
  chatId: 'c',
  seq: seq,
  role: role,
  createdAt: createdAt,
  text: text,
  toolCalls: calls,
  toolCallId: toolCallId,
);

/// Большой результат инструмента: именно он должен попасть в кэш между шагами.
final _bigText = List.generate(
  400,
  (i) => 'row $i: ${'value-' * 6}',
).join('\n');

/// История хода. [nonce] уникален на запуск, поэтому кэш не получает попаданий
/// от предыдущих запусков. [sent] — время создания сообщений: оно должно быть
/// одним и тем же на всех шагах хода, как в базе, иначе метка в тексте
/// отличается между шагами и кэш не читается уже с первого сообщения.
List<ChatMessage> _history(
  String nonce, {
  required int steps,
  required DateTime sent,
}) => [
  _msg(
    'u-$nonce',
    1,
    MessageRole.user,
    sent,
    text: 'Nonce $nonce. Прочитай big.txt и ответь одним символом.',
  ),
  _msg(
    'a1',
    2,
    MessageRole.assistant,
    sent,
    calls: const [
      ToolCallRef(
        id: 'call1',
        name: 'read_file',
        arguments: '{"path":"big.txt"}',
      ),
    ],
  ),
  _msg('t1', 3, MessageRole.tool, sent, text: _bigText, toolCallId: 'call1'),
  if (steps > 1) ...[
    _msg(
      'a2',
      4,
      MessageRole.assistant,
      sent,
      calls: const [
        ToolCallRef(
          id: 'call2',
          name: 'read_file',
          arguments: '{"path":"small.txt"}',
        ),
      ],
    ),
    _msg('t2', 5, MessageRole.tool, sent, text: 'ok', toolCallId: 'call2'),
  ],
];

const _tools = [
  LlmToolSpec(
    name: 'read_file',
    description: 'Read a file',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
    },
  ),
];

/// Запрос так, как его собирает приложение. Для контроля [stamped] = false из
/// user-сообщений убирается строка `[sent at: ...]`: это единственное отличие
/// контрольного запроса от боевого.
List<LlmMessage> _requestMessages(
  List<ChatMessage> history, {
  bool stamped = true,
}) {
  final messages = ContextBuilder().build(
    ContextInput(
      chat: _chat(),
      host: _host(),
      messages: history,
      state: SessionStateRevision(
        id: 'r',
        chatId: 'c',
        createdAt: DateTime(2026),
      ),
      workspace: const WorkspaceSnapshot(),
      recentWindow: 40,
    ),
  );
  if (stamped) return messages;
  final stamp = RegExp(r'\n\[sent at: [^\]]*\]$');
  return [
    for (final m in messages)
      m.role == LlmRole.user
          ? LlmMessage(
              role: m.role,
              content: m.content.replaceFirst(stamp, ''),
              files: m.files,
            )
          : m,
  ];
}

OpenRouterLlmProvider _provider() => OpenRouterLlmProvider(
  readConfig: () async => LlmProviderConfig(apiKey: _apiKey),
);

/// Один запрос через провайдер приложения. Ошибка не бросается наружу: она
/// попадает в отчёт, чтобы было видно, на каком шаге что сломалось.
Future<Map<String, Object?>> _call(
  OpenRouterLlmProvider provider,
  _Budget budget, {
  required Map<String, Object?> label,
  required LlmRequest request,
}) async {
  budget.spend();
  final reply = StringBuffer();
  // Рассуждения и вызовы инструментов фиксируем отдельно: без них пустой ответ
  // при лимите токенов неотличим от сбоя.
  var reasoningChars = 0;
  var toolCalls = <String>[];
  LlmUsage? usage;
  String? finishReason;
  String? error;
  try {
    await for (final event in provider.stream(request)) {
      if (event is LlmTextDelta) reply.write(event.text);
      if (event is LlmReasoningDelta) reasoningChars += event.text.length;
      if (event is LlmCompleted) {
        usage = event.usage;
        finishReason = event.finishReason;
        toolCalls = [for (final call in event.toolCalls) call.name];
      }
    }
  } on Object catch (e) {
    error = Redactor.redact(e.toString());
  }
  final text = Redactor.redact(reply.toString());
  return {
    ...label,
    'promptTokens': usage?.promptTokens,
    'cachedPromptTokens': usage?.cachedPromptTokens,
    'cacheWritePromptTokens': usage?.cacheWritePromptTokens,
    'completionTokens': usage?.completionTokens,
    'finishReason': finishReason,
    'reasoningChars': reasoningChars,
    'toolCalls': toolCalls,
    'reply': text.characters.take(80).toString(),
    'error': error,
  };
}

void _report(List<Map<String, Object?>> rows) {
  stdout.writeln('LIVE_REPORT ${jsonEncode(rows)}');
}

void main() {
  test('кэш между шагами одного хода', skip: _skip, () async {
    final provider = _provider();
    final budget = _Budget(_maxPairs * 4);
    final rows = <Map<String, Object?>>[];

    // Пары повторяются, чтобы отличить закономерность от разового результата.
    // Внутри пары схемы идут подряд; порядок чередуется, чтобы не было
    // систематического сдвига. У каждого прогона свой nonce, поэтому кэш
    // стартует с нуля.
    for (var pair = 1; pair <= _maxPairs; pair++) {
      final schemes = pair.isOdd ? [true, false] : [false, true];
      for (final stamped in schemes) {
        final scheme = stamped ? 'stamped' : 'control';
        final sent = DateTime.now();
        final nonce = '${sent.microsecondsSinceEpoch}-$pair-$scheme';
        for (final step in [1, 2]) {
          rows.add(
            await _call(
              provider,
              budget,
              label: {'pair': pair, 'scheme': scheme, 'step': step},
              request: LlmRequest(
                model: _model,
                messages: _requestMessages(
                  _history(nonce, steps: step, sent: sent),
                  stamped: stamped,
                ),
                tools: _tools,
                maxTokens: 16,
                promptCaching: true,
              ),
            ),
          );
        }
      }
    }

    _report(rows);
    expect(
      rows.where((r) => r['error'] != null),
      isEmpty,
      reason: 'запросы должны проходить; ошибки — в LIVE_REPORT',
    );
  });

  test(
    'promptCaching не ломает запрос к не-Anthropic модели',
    skip: _skip,
    () async {
      final provider = _provider();
      final budget = _Budget(1);
      final nonce = 'other-${DateTime.now().microsecondsSinceEpoch}';

      final row = await _call(
        provider,
        budget,
        label: {'mode': 'other-model', 'step': 1},
        request: LlmRequest(
          model: _otherModel,
          messages: _requestMessages(
            _history(nonce, steps: 1, sent: DateTime.now()),
          ),
          tools: _tools,
          maxTokens: 16,
          promptCaching: true,
        ),
      );

      _report([row]);
      expect(
        row['error'],
        isNull,
        reason: 'cache_control не должен ломать запрос',
      );
    },
  );
}
