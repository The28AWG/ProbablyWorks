/// Группы списка по времени последнего обновления: сегодня, вчера, раньше.
enum DayBucket { today, yesterday, earlier }

DayBucket dayBucket(DateTime value, {DateTime? now}) {
  final local = value.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final todayDate = DateTime(today.year, today.month, today.day);
  final valueDate = DateTime(local.year, local.month, local.day);
  final days = todayDate.difference(valueDate).inDays;
  if (days <= 0) return DayBucket.today;
  if (days == 1) return DayBucket.yesterday;
  return DayBucket.earlier;
}

/// Короткая метка времени: `14:05` для сегодняшней даты, иначе `03.11`.
String formatShortTime(DateTime value, {DateTime? now}) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  if (dayBucket(value, now: now) == DayBucket.today) {
    return '${two(local.hour)}:${two(local.minute)}';
  }
  return '${two(local.day)}.${two(local.month)}';
}

/// Календарная дата в локальном времени: `2026-11-12`.
///
/// Сервер присылает метки в UTC, поэтому перед разбором полей даты
/// значение нужно перевести в локальную зону.
String formatIsoDate(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
