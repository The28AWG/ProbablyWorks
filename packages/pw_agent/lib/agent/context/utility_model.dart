import 'package:pw_agent/core/data/settings_repository.dart';

/// Выбирает модель для служебных проходов: сжатие истории и память проекта.
///
/// Цепочка: модель памяти → модель заголовков → [fallback]. Явно выбранная
/// модель основной роли имеет приоритет: если [fallback] совпадает с
/// настроенной служебной моделью, возвращается именно она. Неизвестная
/// каталогу модель пропускается, если передан [isKnown]; иначе проверка
/// остаётся на вызывающей стороне.
///
/// Возвращает id модели или [fallback], если ничего не настроено.
Future<String?> resolveUtilityModel({
  required SettingsRepository settings,
  required String? fallback,
  bool Function(String model)? isKnown,
}) async {
  for (final key in const [
    SettingsRepository.keyMemoryModel,
    SettingsRepository.keyTitleModel,
  ]) {
    final configured = await settings.read(key);
    if (configured == null || configured.isEmpty) continue;
    if (configured == fallback) return configured;
    if (isKnown == null || isKnown(configured)) return configured;
  }
  return fallback;
}
