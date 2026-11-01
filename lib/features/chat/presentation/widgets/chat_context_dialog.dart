import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Диалог окна контекста: заполнение и действие «Сжать историю».
///
/// Сжатие запускается вручную только когда агент не работает и данные о заполнении уже есть.
class ChatContextDialog extends StatelessWidget {
  const ChatContextDialog({
    required this.used,
    required this.limit,
    required this.running,
    required this.onCompact,
    super.key,
  });

  /// Заполнено токенов по последнему ответу модели или `null`, пока данных нет.
  final int? used;
  final int limit;
  final bool running;
  final VoidCallback onCompact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final used = this.used;
    final canCompact = used != null && !running;
    return AlertDialog(
      title: Text(l10n.chatContextTitle),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.chatContextHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (used == null)
              Text(l10n.contextNoData, style: theme.textTheme.bodyMedium)
            else
              ContextUsageBar(
                label: l10n.contextUsage(
                  _groupDigits(used),
                  _groupDigits(limit),
                ),
                fraction: limit <= 0
                    ? 0
                    : (used / limit).clamp(0, 1).toDouble(),
              ),
            const SizedBox(height: AppSpacing.lg),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: canCompact
                    ? () {
                        Navigator.of(context).pop();
                        onCompact();
                      }
                    : null,
                icon: const Icon(Icons.compress, size: 18),
                label: Text(l10n.compactHistory),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  /// `128000` → `128 000`.
  static String _groupDigits(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}
