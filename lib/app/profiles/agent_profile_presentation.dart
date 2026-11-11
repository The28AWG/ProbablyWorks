import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Название профиля для интерфейса.
///
/// Локальный профиль не хранит пользовательское имя: он показывается так же,
/// как локальный Host — с учётом платформы и языка.
String agentProfileTitle(AgentProfile profile, AppLocalizations l10n) =>
    profile.isLocal ? localHostTitle(l10n) : profile.name;

/// Иконка профиля: компьютер/телефон для локального, облако для удалённого.
IconData agentProfileIcon(AgentProfile profile) =>
    profile.isLocal ? localHostIcon() : Icons.cloud_outlined;
