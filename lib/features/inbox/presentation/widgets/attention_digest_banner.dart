import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';

/// Компактная строка «пока вас не было».
///
/// Карточка не раскрывается: в ней только сводка и переход во входящие.
/// Подробная разбивка по чатам живёт во «Входящих», поэтому длинный список не
/// вытесняет содержимое вкладки. Строка занимает всю ширину и отделена от
/// контента только нижним разделителем — так она читается как часть оболочки,
/// а свайп начинается от края.
class AttentionDigestBanner extends StatelessWidget {
  const AttentionDigestBanner({
    required this.digest,
    required this.onDismiss,
    required this.onReview,
    super.key,
  });

  final AttentionDigest digest;

  /// Убирает карточку до следующего возврата в приложение.
  final VoidCallback onDismiss;

  /// Открывает входящие и убирает карточку.
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < AppBreakpoints.tiny;
        return SizedBox(
          width: double.infinity,
          child: Dismissible(
            key: const ValueKey('attention-digest'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) => onDismiss(),
            background: ColoredBox(
              color: theme.colorScheme.errorContainer,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.lg),
                  child: Icon(
                    Icons.close,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
            child: Material(
              color: theme.colorScheme.surfaceContainerLow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.inboxDigestTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                _summary(l10n, digest),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (compact)
                          IconButton(
                            onPressed: onReview,
                            tooltip: l10n.inboxDigestReview,
                            icon: const Icon(Icons.arrow_forward),
                          )
                        else ...[
                          TextButton(
                            onPressed: onReview,
                            child: Text(l10n.inboxDigestReview),
                          ),
                          IconButton(
                            onPressed: onDismiss,
                            tooltip: l10n.commonClose,
                            icon: const Icon(Icons.close, size: 18),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: theme.colorScheme.outlineVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Сводка только из значимых чисел.
///
/// Завершённые ходы и разбивка по типам решений остаются во входящих: карточка
/// должна оставаться одной строкой. Если решений и проблем нет, показываем
/// новые сообщения — это единственное, что осталось.
String _summary(AppLocalizations l10n, AttentionDigest digest) => [
  if (digest.decisions > 0) l10n.inboxDigestDecisions(digest.decisions),
  if (digest.problems > 0) l10n.inboxDigestProblems(digest.problems),
  if (digest.newMessages > 0) l10n.inboxDigestMessages(digest.newMessages),
].join(' · ');
