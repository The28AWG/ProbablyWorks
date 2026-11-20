import 'package:material_ui/material_ui.dart';

/// Ответ на вопрос с двумя действиями в [ConfirmDialog.choose].
enum ConfirmChoice {
  /// Основное действие.
  primary,

  /// Альтернативное действие: не отказ от операции, а другой её вариант.
  secondary,
}

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

  /// Вопрос с двумя действиями и отменой. Нужен там, где «нет» — это не отказ
  /// от операции, а другой её вариант: например, перенести задачи при
  /// дублировании чата или отбросить их.
  ///
  /// null — пользователь отменил или закрыл диалог, операцию начинать не нужно.
  static Future<ConfirmChoice?> choose(
    BuildContext context, {
    required String title,
    required String message,
    required String cancelLabel,
    required String secondaryLabel,
    required String primaryLabel,
  }) => showDialog<ConfirmChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(
            cancelLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, ConfirmChoice.secondary),
          child: Text(
            secondaryLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, ConfirmChoice.primary),
          child: Text(
            primaryLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );

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
    int? maxLength,
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
      maxLength: maxLength,
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
    required this.maxLength,
  });

  final String title;
  final String cancelLabel;
  final String confirmLabel;
  final String initialText;
  final String? hint;
  final int minLines;
  final int maxLines;
  final int? maxLength;

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
        maxLength: widget.maxLength,
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
