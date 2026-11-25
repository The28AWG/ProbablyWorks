import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/state/shared_state.dart';

/// Поток изменений доменных сервисов для синхронизации окон.
///
/// Сервисы публикуют факт изменения ресурса, а не HTTP-маршрут: новый маршрут
/// поверх того же сервиса получает синхронизацию автоматически. Подписчик
/// (демон) превращает событие в SSE `stateAreaChanged`; локальный GUI просто
/// не подписывается, поэтому публикация для него ничего не стоит.
@singleton
final class DomainChangeBus {
  final _changes = StreamController<SharedResource>.broadcast();

  /// Изменённые общие ресурсы. Поток широковещательный: подписчиков может быть
  /// несколько (демон и, например, встроенная диагностика).
  Stream<SharedResource> get changes => _changes.stream;

  /// Сообщает, что ресурс изменён. Повторные события допустимы: клиент
  /// перечитывает снимок, а не применяет дельту.
  void publish(SharedResource resource) {
    if (!_changes.isClosed) _changes.add(resource);
  }

  /// Закрывает поток. Вызывается только владельцем жизненного цикла.
  Future<void> close() => _changes.close();
}
