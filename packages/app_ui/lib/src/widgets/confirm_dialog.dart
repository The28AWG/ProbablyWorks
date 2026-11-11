import 'package:material_ui/material_ui.dart';

/// Единые диалоги: подтверждение действия и ввод текста. Вместо ручных `AlertDialog` в экранах.
/// Деструктивное действие [destructive] выделяется цветом ошибки.
abstract final class ConfirmDialog {
  const ConfirmDialog._();

  /// Возвращает true, если пользователь подтвердил. Закрытие без выбора — false.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String cancelLabel,
    required String confirmLabel,
    String? message,
    Widget? content,
    bool destructive = false,
    bool barrierDismissible = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          content: content ?? (message == null ? null : Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(
                cancelLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                confirmLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  /// Диалог с одним полем ввода (переименование, редактирование сообщения).
  /// Возвращает введённый текст или null при отмене.
  static Future<String?> prompt(
    BuildContext context, {
    required String title,
    required String cancelLabel,
    required String confirmLabel,
    String initialText = '',
    String? hint,
    int minLines = 1,
    int maxLines = 1,
  }) => showDialog<String>(
    context: context,
    builder: (_) => _PromptDialog(
      title: title,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      initialText: initialText,
      hint: hint,
      minLines: minLines,
      maxLines: maxLines,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.initialText,
    required this.hint,
    required this.minLines,
    required this.maxLines,
  });

  final String title;
  final String cancelLabel;
  final String confirmLabel;
  final String initialText;
  final String? hint;
  final int minLines;
  final int maxLines;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    content: SizedBox(
      width: 420,
      child: TextField(
        controller: _controller,
        autofocus: true,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        decoration: InputDecoration(hintText: widget.hint),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(
          widget.cancelLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(
          widget.confirmLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}
