import 'package:pw_agent/agent/domain/attention_digest.dart';

/// Дайджест «пока вас не было».
///
/// Отдельный интерфейс, а не расширение [AttentionApi]: старые серверы и
/// тестовые реализации входящих не должны ломаться из-за нового маршрута.
/// Встроенный агент считает сводку по общей базе, удалённый — поверх
/// `GET /attention/digest`.
abstract interface class AttentionDigestApi {
  /// Сводка непрочитанного, завершённых ходов, карточек и проблем.
  Future<AttentionDigest> attentionDigest();
}
