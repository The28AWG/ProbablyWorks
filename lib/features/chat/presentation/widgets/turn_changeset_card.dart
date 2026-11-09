import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Список путей, затронутых ходом агента, и откат write_file/edit_file.
class TurnChangesetCard extends StatelessWidget {
  const TurnChangesetCard({
    required this.changeset,
    required this.enabled,
    super.key,
  });

  final TurnChangeset changeset;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (changeset.isEmpty) return const SizedBox.shrink();
    final paths = [for (final change in changeset.files.values) change]
      ..sort((a, b) => a.path.compareTo(b.path));

    String kindLabel(TurnFileKind kind) => switch (kind) {
      TurnFileKind.created => l10n.turnChangesetCreated,
      TurnFileKind.modified => l10n.turnChangesetModified,
      TurnFileKind.deleted => l10n.turnChangesetDeleted,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.turnChangesetTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (changeset.nonRecoverable)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  l10n.turnChangesetNonRecoverable,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            if (changeset.rolledBack)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  l10n.turnChangesetRolledBack,
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            for (final change in paths)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(
                        kindLabel(change.kind),
                        style: TextStyle(color: scheme.outline, fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        change.path,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (changeset.canRollback && enabled && !changeset.rolledBack)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: () => _confirmRollback(context),
                  child: Text(l10n.turnChangesetRollback),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRollback(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.turnChangesetRollbackConfirmTitle,
      message: l10n.turnChangesetRollbackConfirmBody,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.turnChangesetRollback,
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    context.read<ChatBloc>().add(ChatTurnRollbackRequested(changeset.turnId));
  }
}
