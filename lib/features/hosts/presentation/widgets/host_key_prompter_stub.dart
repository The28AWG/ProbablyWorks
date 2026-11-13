import 'package:material_ui/material_ui.dart';

/// Web-заглушка: SSH-подключений из браузера нет, подтверждать ключ нечего.
class HostKeyPrompter extends StatelessWidget {
  const HostKeyPrompter({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
