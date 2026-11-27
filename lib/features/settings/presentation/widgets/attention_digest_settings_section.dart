import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Настройка показа дайджеста «пока вас не было».
///
/// Читает клиентскую настройку напрямую: это не свойство агента, а решение
/// устройства показывать лишнюю карточку. При выключении уже показанная
/// карточка сразу убирается.
class AttentionDigestSettingsSection extends StatefulWidget {
  const AttentionDigestSettingsSection({super.key});

  @override
  State<AttentionDigestSettingsSection> createState() =>
      _AttentionDigestSettingsSectionState();
}

class _AttentionDigestSettingsSectionState
    extends State<AttentionDigestSettingsSection> {
  final _settings = getIt<ClientSettings>();
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final raw = await _settings.read(ClientSettingsKeys.attentionDigestEnabled);
    if (!mounted) return;
    setState(() => _enabled = raw != 'false');
  }

  Future<void> _set(bool value) async {
    await _settings.write(
      ClientSettingsKeys.attentionDigestEnabled,
      value ? 'true' : 'false',
    );
    if (!mounted) return;
    setState(() => _enabled = value);
    if (!value) context.read<ChatListCubit>().dismissDigest();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = _enabled;
    if (enabled == null) return const SizedBox.shrink();
    return AppSection(
      title: l10n.settingsDigestTitle,
      description: l10n.settingsDigestHint,
      children: [
        AppChoiceGroup<bool>(
          options: [
            AppChoiceOption(
              value: true,
              title: l10n.settingsDigestOn,
              subtitle: l10n.settingsDigestOnHint,
              icon: const Icon(Icons.notifications_active_outlined),
            ),
            AppChoiceOption(
              value: false,
              title: l10n.settingsDigestOff,
              subtitle: l10n.settingsDigestOffHint,
              icon: const Icon(Icons.notifications_off_outlined),
            ),
          ],
          selected: enabled,
          onChanged: (value) => unawaited(_set(value)),
        ),
      ],
    );
  }
}
