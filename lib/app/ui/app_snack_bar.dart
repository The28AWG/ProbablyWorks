import 'package:material_ui/material_ui.dart';

/// Единые уведомления: плавающая полоса внизу с необязательным действием.
/// Заменяет разрозненные `ScaffoldMessenger.showSnackBar` с ручными стилями.
abstract final class AppSnackBar {
  const AppSnackBar._();

  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: actionLabel == null || onAction == null
              ? null
              : SnackBarAction(label: actionLabel, onPressed: onAction),
        ),
      );
  }
}
