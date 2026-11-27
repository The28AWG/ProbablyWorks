/// Заглушка бейджа для платформ без DOM.
///
/// На VM и в тестах браузерного API нет; ничего не делаем, чтобы общий код
/// не зависел от `package:web`.
Future<void> setWebAppBadge(int count) {
  assert(count >= 0, 'badge count must not be negative');
  return Future<void>.value();
}
