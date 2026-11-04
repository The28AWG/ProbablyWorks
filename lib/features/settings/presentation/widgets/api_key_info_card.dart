import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Карточка сведений о ключе из сервиса: метка, расходы, лимит, срок и тариф.
/// Загрузка, ошибка и пустое состояние показываются внутри карточки, экран при этом работает.
class ApiKeyInfoCard extends StatelessWidget {
  const ApiKeyInfoCard({
    required this.info,
    required this.loading,
    required this.error,
    required this.onRetry,
    super.key,
  });

  /// Сведения последней успешной проверки; null — ещё не загружены.
  final LlmKeyInfo? info;

  /// Запрос в полёте: в заголовке показывается спиннер.
  final bool loading;

  /// Ошибка последнего запроса; null после успеха.
  final String? error;

  /// Повтор запроса по кнопке в баннере ошибки.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final info = this.info;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.settingsKeyInfoTitle,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (loading)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppBanner(
              margin: EdgeInsets.zero,
              tone: AppTone.danger,
              icon: Icons.error_outline,
              message: l10n.commonError(error!),
              action: TextButton(
                onPressed: loading ? null : onRetry,
                child: Text(
                  l10n.commonRetry,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          if (info == null)
            if (error == null && !loading) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.settingsKeyInfoEmpty,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          if (info != null) ...[
            const SizedBox(height: AppSpacing.md),
            _InfoRow(
              label: l10n.settingsKeyLabel,
              value: info.label,
              mono: true,
            ),
            _InfoRow(label: l10n.settingsKeyUsage, value: _money(info.usage)),
            _InfoRow(
              label: l10n.settingsKeyLimit,
              value: info.limit == null
                  ? l10n.settingsKeyNoLimit
                  : _money(info.limit!),
            ),
            if (info.limit != null)
              _InfoRow(
                label: l10n.settingsKeyRemaining,
                value: _money(info.limitRemaining ?? 0),
              ),
            if (info.limitReset != null)
              _InfoRow(
                label: l10n.settingsKeyLimitReset,
                value: info.limitReset!,
              ),
            _InfoRow(
              label: l10n.settingsKeyExpires,
              value: info.expiresAt == null
                  ? l10n.settingsKeyNeverExpires
                  : _date(info.expiresAt!),
            ),
            _InfoRow(
              label: l10n.settingsKeyPlan,
              value: info.isFreeTier
                  ? l10n.settingsKeyPlanFree
                  : l10n.settingsKeyPlanPaid,
            ),
          ],
        ],
      ),
    );
  }

  /// `12.5` → `$12.50`: суммы в USD, как в выборе модели.
  static String _money(num usd) => '\$${usd.toStringAsFixed(2)}';

  /// Дата истечения в локальном времени: `31.12.2027`.
  static String _date(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}';
  }
}

/// Строка «подпись — значение». Длинное значение обрезается, подпись не сжимается.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: mono
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: AppTheme.monoFamily,
                      fontSize: 13,
                    )
                  : theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
