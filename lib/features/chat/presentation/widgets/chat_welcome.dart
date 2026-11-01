import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Пустой чат: короткое приветствие, где будет работать агент, и три стартовые подсказки.
/// Подсказка подставляется в поле ввода; отправляет её пользователь сам.
class ChatWelcome extends StatelessWidget {
  const ChatWelcome({
    required this.hostLabel,
    required this.onSuggest,
    super.key,
  });

  final String hostLabel;
  final ValueChanged<String> onSuggest;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final suggestions = [
      l10n.chatSuggestion1,
      l10n.chatSuggestion2,
      l10n.chatSuggestion3,
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: AppRadius.xlAll,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Icon(
                    Icons.auto_awesome_outlined,
                    size: 24,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                l10n.chatWelcomeTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.chatWelcomeSubtitle(hostLabel),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final text in suggestions)
                    ActionChip(
                      avatar: const Icon(Icons.north_east, size: 16),
                      label: Text(text),
                      onPressed: () => onSuggest(text),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
