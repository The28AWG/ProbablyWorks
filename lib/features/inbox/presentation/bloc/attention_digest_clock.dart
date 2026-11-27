import 'package:probably_works/core/settings/client_settings.dart';

/// Сколько окно должно отсутствовать, чтобы дайджест считался полезным.
///
/// Короткий переход между вкладками или окнами — не повод показывать сводку.
/// Порог локальный: он не влияет на то, какие счётчики вернёт сервер.
const attentionDigestAwayThreshold = Duration(minutes: 15);

/// Отслеживает, как долго окно не было активным.
///
/// Активность — локальное знание устройства: сервер не может отличить
/// выгруженное мобильное приложение от открытого окна, которое просто никто не
/// трогает. Время последней активности хранится в клиентских настройках, а
/// сами счётчики дайджеста приходят с сервера и общие для всех экранов.
final class AttentionDigestClock {
  AttentionDigestClock(
    this._settings, {
    required this.profileId,
    DateTime Function()? now,
    this.awayThreshold = attentionDigestAwayThreshold,
  }) : _now = now ?? DateTime.now;

  final ClientSettings _settings;

  /// Профиль агента: у двух подключений своя история отсутствия.
  final String profileId;

  final DateTime Function() _now;
  final Duration awayThreshold;

  String get _key =>
      '${ClientSettingsKeys.attentionDigestLastActiveAt}.$profileId';

  /// Пора ли показывать дайджест.
  ///
  /// `false`, если окно раньше не отмечалось: при первом запуске неизвестно,
  /// сколько длилось отсутствие, и лучше не угадывать.
  Future<bool> shouldShow() async {
    final away = await _awayDuration();
    return away != null && away >= awayThreshold;
  }

  /// Запоминает, что окно сейчас активно.
  ///
  /// Вызывается при уходе в фон и после проверки при возврате. Запись
  /// асинхронна, но потеря отметки не ломает дайджест: она лишь откладывает
  /// следующий показ.
  Future<void> rememberActive() =>
      _settings.write(_key, _now().toUtc().toIso8601String());

  Future<Duration?> _awayDuration() async {
    final raw = await _settings.read(_key);
    if (raw == null) return null;
    final at = DateTime.tryParse(raw);
    if (at == null) return null;
    final away = _now().toUtc().difference(at.toUtc());
    // Часы могли перевести назад: отрицательное отсутствие — не отсутствие.
    return away.isNegative ? Duration.zero : away;
  }
}
