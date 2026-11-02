/// Типизированные ошибки приложения. Сообщения не содержат секретов.
sealed class AppFailure implements Exception {
  const AppFailure(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Ошибка провайдера ИИ (OpenRouter и т.п.).
final class LlmFailure extends AppFailure {
  const LlmFailure(
    super.message, {
    this.statusCode,
    this.retryable = false,
    this.contextLengthExceeded = false,
    this.modelNotFound = false,
  });

  final int? statusCode;
  final bool retryable;
  final bool contextLengthExceeded;

  /// Провайдер не знает модель: её убрали из OpenRouter, хотя в кеше она ещё есть.
  final bool modelNotFound;
}

/// Ошибка исполнения на Host.
final class HostFailure extends AppFailure {
  const HostFailure(super.message, {this.kind = HostFailureKind.spawnFailed});

  final HostFailureKind kind;
}

enum HostFailureKind {
  spawnFailed,
  connectionLost,
  hostKeyMismatch,
  hostKeyRejected,
  authFailed,
}

/// Действие запрещено политикой. Не обходится настройками и AGENTS.md.
final class PolicyDenied extends AppFailure {
  const PolicyDenied(super.message);
}
