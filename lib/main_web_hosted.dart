import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/app.dart';
import 'package:probably_works/app/bootstrap/web_bootstrap.dart';

/// Web-клиент, который отдаёт сам сервер ProbablyWorks.
///
/// В отличие от [main_web.dart] использует path-стратегию: браузер видит
/// `/a/<profileId>/chats`, а сервер отдаёт `index.html` для неизвестных
/// не-API путей.
Future<void> main() async {
  await bootstrapWeb(hosted: true);
  usePathUrlStrategy();
  runApp(const ProbablyWorksApp());
}
