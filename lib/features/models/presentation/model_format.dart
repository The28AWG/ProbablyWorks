/// Время последнего обновления каталога для подписи, например `02.11 20:54` (локальное время).
String formatModelSyncTime(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)} '
      '${two(local.hour)}:${two(local.minute)}';
}
