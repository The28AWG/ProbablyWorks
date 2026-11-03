import 'package:flutter_test/flutter_test.dart';
import 'package:openrouter/openrouter.dart';
import 'package:probably_works/providers/ai/openrouter/openrouter_llm_provider.dart';

void main() {
  test('404 means the model is gone: not retryable, flagged as missing', () {
    final failure = llmFailureOf(
      const OpenRouterException(message: 'No endpoints found', statusCode: 404),
    );
    expect(failure.modelNotFound, isTrue);
    expect(failure.retryable, isFalse);
    expect(failure.statusCode, 404);
  });

  test('other statuses are not treated as a missing model', () {
    for (final status in [400, 401, 402, 429, 500, 503]) {
      final failure = llmFailureOf(
        OpenRouterException(message: 'boom', statusCode: status),
      );
      expect(failure.modelNotFound, isFalse, reason: 'status $status');
    }
  });

  test('rate limits and server errors stay retryable', () {
    expect(
      llmFailureOf(
        const OpenRouterException(message: 'slow down', statusCode: 429),
      ).retryable,
      isTrue,
    );
    expect(
      llmFailureOf(const OpenRouterException(message: 'oops', statusCode: 502))
          .retryable,
      isTrue,
    );
  });

  test('context overflow is recognised from the message', () {
    expect(
      llmFailureOf(
        const OpenRouterException(
          message: "This model's maximum context length is 8192 tokens",
          statusCode: 400,
        ),
      ).contextLengthExceeded,
      isTrue,
    );
  });

  test('server reason from the JSON body is kept in the failure', () {
    final failure = llmFailureOf(
      const OpenRouterException(
        message: 'HTTP 403',
        statusCode: 403,
        body: '{"error":{"message":"Access denied in your region","code":403}}',
      ),
    );
    expect(failure.statusCode, 403);
    expect(failure.message, 'HTTP 403: Access denied in your region');
  });

  test('secrets echoed by the server are masked', () {
    final failure = llmFailureOf(
      const OpenRouterException(
        message: 'HTTP 401',
        statusCode: 401,
        body: '{"error":{"message":"Invalid key sk-or-v1-abcdef1234567890","code":401}}',
      ),
    );
    expect(failure.message, isNot(contains('abcdef1234567890')));
    expect(failure.message, contains('sk-or-v1-***'));
  });

  test('non-JSON body (proxy page) is shortened, not dropped', () {
    final failure = llmFailureOf(
      OpenRouterException(
        message: 'HTTP 403',
        statusCode: 403,
        body: '<html>\n  <body>${'blocked ' * 100}</body>\n</html>',
      ),
    );
    expect(failure.message, startsWith('HTTP 403: <html>'));
    expect(failure.message.length, lessThan(250));
  });
}
