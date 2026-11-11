import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/context/context_breakdown.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/chat_usage.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Диалог окна контекста: заполнение, разбивка, стоимость и дневной лимит.
///
/// Сжатие запускается вручную только когда агент не работает и данные о заполнении уже есть.
class ChatContextDialog extends StatelessWidget {
  const ChatContextDialog({
    required this.used,
    required this.limit,
    required this.running,
    required this.onCompact,
    this.breakdown,
    this.lastRequestCostUsd,
    this.dailyCostUsd = 0,
    this.dailyBudgetUsd,
    this.compaction,
    this.onBudgetChanged,
    super.key,
  });

  /// Заполнено токенов по последнему ответу модели или `null`, пока данных нет.
  final int? used;
  final int limit;
  final bool running;
  final VoidCallback onCompact;
  final ContextBreakdown? breakdown;
  final double? lastRequestCostUsd;
  final double dailyCostUsd;
  final double? dailyBudgetUsd;

  /// Последнее сжатие истории: время, причина и граница.
  final ChatCompactionInfo? compaction;
  final ValueChanged<double?>? onBudgetChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final used = this.used;
    final canCompact = used != null && !running;
    final breakdown = this.breakdown;
    return AlertDialog(
      title: Text(
        l10n.chatContextTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
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
              if (breakdown != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  l10n.contextBreakdownTitle,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                _BreakdownRow(
                  label: l10n.contextSystem,
                  chars: breakdown.systemChars,
                  tokens: breakdown.systemTokens,
                ),
                _BreakdownRow(
                  label: l10n.contextHistory,
                  chars: breakdown.historyChars,
                  tokens: breakdown.historyTokens,
                ),
                _BreakdownRow(
                  label: l10n.contextToolResults,
                  chars: breakdown.toolResultChars,
                  tokens: breakdown.toolResultTokens,
                ),
                _BreakdownRow(
                  label: l10n.contextAttachments,
                  chars: breakdown.attachmentBytes,
                  tokens: breakdown.attachmentTokens,
                ),
                _BreakdownRow(
                  label: l10n.contextTools,
                  chars: breakdown.toolSchemaChars,
                  tokens: breakdown.toolSchemaTokens,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              _InfoRow(
                label: l10n.contextLastRequestCost,
                value: _money(lastRequestCostUsd),
              ),
              _InfoRow(
                label: l10n.contextTodayCost,
                value: _money(dailyCostUsd),
              ),
              _InfoRow(
                label: l10n.contextDailyBudget,
                value: dailyBudgetUsd == null
                    ? l10n.contextBudgetNotSet
                    : _money(dailyBudgetUsd),
              ),
              if (onBudgetChanged != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _editBudget(context, l10n),
                    icon: const Icon(Icons.savings_outlined, size: 18),
                    label: Text(l10n.contextSetBudget),
                  ),
                ),
              if (compaction case final info?) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.contextCompacted(info.cutoffSeq, info.summaryChars),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  l10n.contextCompactedAt(
                    _dateTime(info.at),
                    _compactionReason(l10n, info.reason),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
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
                  label: Text(
                    l10n.compactHistory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            l10n.commonClose,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Future<void> _editBudget(BuildContext context, AppLocalizations l10n) async {
    final value = await ConfirmDialog.prompt(
      context,
      title: l10n.contextDailyBudget,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      initialText: dailyBudgetUsd?.toStringAsFixed(2) ?? '',
      hint: l10n.contextBudgetHint,
    );
    if (value == null || !context.mounted) return;
    final text = value.trim().replaceAll(',', '.');
    if (text.isEmpty) {
      onBudgetChanged?.call(null);
      Navigator.of(context).pop();
      return;
    }
    final parsed = double.tryParse(text);
    if (parsed == null || parsed < 0) return;
    onBudgetChanged?.call(parsed);
    Navigator.of(context).pop();
  }

  static String _compactionReason(AppLocalizations l10n, String reason) =>
      reason == 'forced'
      ? l10n.contextCompactionForced
      : l10n.contextCompactionThreshold;

  /// Локальные дата и время без зависимости от intl: `2026-11-11 14:05`.
  static String _dateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  static String _money(double? value) {
    if (value == null) return '—';
    if (value == 0) return '\$0.00';
    return '\$${value.toStringAsFixed(4)}';
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

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.chars,
    required this.tokens,
  });

  final String label;
  final int chars;
  final int tokens;

  @override
  Widget build(BuildContext context) {
    if (chars <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            '~$tokens',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
