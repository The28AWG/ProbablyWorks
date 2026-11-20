import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Вопрос о несработавших задачах при дублировании чата.
///
/// Общий для обоих путей форка — из списка чатов и из ответа в ленте: они
/// должны спрашивать одинаково и не терять задачи молча.
///
/// Возвращает true — перенести, false — отбросить, null — отменить форк.
Future<bool?> askForkTasksChoice(BuildContext context, int pending) async {
  final l10n = AppLocalizations.of(context);
  final choice = await ConfirmDialog.choose(
    context,
    title: l10n.chatsForkTasksTitle,
    message: l10n.chatsForkTasksMessage(pending),
    cancelLabel: l10n.commonCancel,
    secondaryLabel: l10n.chatsForkTasksDiscard,
    primaryLabel: l10n.chatsForkTasksCopy,
  );
  return switch (choice) {
    ConfirmChoice.primary => true,
    ConfirmChoice.secondary => false,
    null => null,
  };
}
