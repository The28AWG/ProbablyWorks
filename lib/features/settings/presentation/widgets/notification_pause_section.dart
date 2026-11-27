import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_pause_api.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';

/// Настройка общей паузы уведомлений.
///
/// Раздел читает снимок входящих и слушает его изменения: срок общий для всех
/// устройств, поэтому пауза, поставленная на телефоне, сразу видна на
/// компьютере и наоборот. Список кнопок короткий, как у «напомнить позже»:
/// быстрые сценарии важнее календаря.
class NotificationPauseSection extends StatefulWidget {
  const NotificationPauseSection({
    required this.attentionApi,
    required this.pauseApi,
    super.key,
  });

  final AttentionApi attentionApi;
  final AttentionPauseApi pauseApi;

  @override
  State<NotificationPauseSection> createState() =>
      _NotificationPauseSectionState();
}

class _NotificationPauseSectionState extends State<NotificationPauseSection> {
  NotificationPause? _pause;
  StreamSubscription<AttentionSnapshot>? _sub;
  var _loading = true;
  var _supported = true;
  String? _error;

  /// Ревизия последнего применённого снимка. Ответ `GET /attention` мог
  /// прийти после SSE-события: без проверки раздел вернул бы старое состояние.
  var _revision = -1;

  @override
  void initState() {
    super.initState();
    _sub = widget.attentionApi.attentionChanges.listen(_onSnapshot);
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _onSnapshot(AttentionSnapshot snapshot) => _applySnapshot(snapshot);

  /// Применяет снимок, только если он не старше уже показанного.
  void _applySnapshot(AttentionSnapshot snapshot) {
    if (!mounted) return;
    setState(() {
      if (snapshot.revision >= _revision) {
        _revision = snapshot.revision;
        _pause = snapshot.pause;
      }
      // Демон могли обновить при открытом приложении: поддержка паузы
      // появляется вместе с первым снимком нового сервера.
      _supported = widget.pauseApi.supportsPause;
    });
  }

  Future<void> _load() async {
    try {
      final snapshot = await widget.attentionApi.attention();
      if (!mounted) return;
      _applySnapshot(snapshot);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _apply(NotificationPauseChoice choice) async {
    try {
      if (choice == NotificationPauseChoice.resume) {
        await widget.pauseApi.resumeNotifications();
      } else {
        final until = choice.deadline(DateTime.now());
        final reason = choice.reason;
        if (until == null || reason == null) return;
        await widget.pauseApi.pauseNotifications(until, reason: reason);
      }
      await _load();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_supported) return const SizedBox.shrink();
    final pause = _pause;
    return AppSection(
      title: l10n.settingsPauseTitle,
      description: l10n.settingsPauseHint,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    pause == null
                        ? Icons.notifications_outlined
                        : Icons.notifications_off_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      pause == null
                          ? l10n.settingsPauseTitle
                          : l10n.settingsPauseActive(
                              notificationPauseReasonLabel(l10n, pause.reason),
                              formatNotificationPauseUntil(l10n, pause.until),
                            ),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
              if (_error case final error?) ...[
                const SizedBox(height: AppSpacing.md),
                AppBanner(
                  message: l10n.commonError(error),
                  tone: AppTone.danger,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  if (pause == null) ...[
                    FilledButton(
                      onPressed: () => _apply(NotificationPauseChoice.focus),
                      child: Text(l10n.settingsPauseFocus),
                    ),
                    OutlinedButton(
                      onPressed: () => _apply(NotificationPauseChoice.meeting),
                      child: Text(l10n.settingsPauseMeeting),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          _apply(NotificationPauseChoice.overnight),
                      child: Text(l10n.settingsPauseOvernight),
                    ),
                  ] else
                    TextButton.icon(
                      onPressed: () => _apply(NotificationPauseChoice.resume),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: Text(l10n.notificationPauseResume),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
