import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Ставит число на иконку установленного web-приложения и в заголовок вкладки.
///
/// `setAppBadge` поддерживают не все браузеры: отсутствие метода или отказ
/// разрешения не должны ломать приложение. Отказ приходит и отклонённым
/// промисом, поэтому вызов ожидается внутри `try`: заголовок обновляется
/// в любом случае и остаётся запасной поверхностью там, где бейджа нет.
Future<void> setWebAppBadge(int count) async {
  web.document.title = count > 0 ? '($count) ProbablyWorks' : 'ProbablyWorks';
  final navigator = web.window.navigator;
  try {
    if (count > 0) {
      await navigator.setAppBadge(count).toDart;
    } else {
      await navigator.clearAppBadge().toDart;
    }
  } on Object {
    // Браузер без Badging API или без разрешения: остаётся заголовок вкладки.
  }
}
