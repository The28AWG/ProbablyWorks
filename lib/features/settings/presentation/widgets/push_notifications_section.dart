import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/bloc/push_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/push_api.dart';

/// Настройки push-relay конкретного профиля.
class PushNotificationsSection extends StatefulWidget {
  const PushNotificationsSection({required this.api, super.key});

  final PushApi api;

  @override
  State<PushNotificationsSection> createState() =>
      _PushNotificationsSectionState();
}

class _PushNotificationsSectionState extends State<PushNotificationsSection> {
  late final PushNotificationsCubit _cubit;
  final _url = TextEditingController();
  final _token = TextEditingController();
  var _enabled = false;
  var _initialized = false;

  @override
  void initState() {
    super.initState();
    _cubit = PushNotificationsCubit(widget.api)..load();
  }

  @override
  void dispose() {
    _cubit.close();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save(AppLocalizations l10n) async {
    final url = _url.text.trim();
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        AppSnackBar.show(context, l10n.settingsPushInvalidUrl);
        return;
      }
    }
    try {
      await _cubit.save(
        enabled: _enabled,
        relayUrl: url,
        token: _token.text.trim().isEmpty ? null : _token.text.trim(),
      );
      _token.clear();
      if (mounted) AppSnackBar.show(context, l10n.settingsSaved);
    } on Object {
      // Ошибка уже в состоянии кубита.
    }
  }

  Future<void> _test(AppLocalizations l10n) async {
    try {
      await _cubit.test();
      if (mounted) AppSnackBar.show(context, l10n.settingsPushTestSent);
    } on Object catch (error) {
      if (mounted) AppSnackBar.show(context, l10n.commonError('$error'));
    }
  }

  Future<void> _clearToken(AppLocalizations l10n) async {
    try {
      await _cubit.save(
        enabled: false,
        relayUrl: _url.text.trim(),
        clearToken: true,
      );
      _enabled = false;
      if (mounted) AppSnackBar.show(context, l10n.settingsSaved);
    } on Object {
      // Ошибка уже в состоянии кубита.
    }
  }

  void _onState(BuildContext context, PushNotificationsState state) {
    if (_initialized || state.loading) return;
    _enabled = state.settings.enabled;
    _url.text = state.settings.relayUrl;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<PushNotificationsCubit, PushNotificationsState>(
        listener: _onState,
        builder: (context, state) {
          if (state.loading) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return AppSection(
            title: l10n.settingsPushTitle,
            description: l10n.settingsPushHint,
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.settingsPushEnabled,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                        Switch(
                          value: _enabled,
                          onChanged: state.saving
                              ? null
                              : (value) => setState(() => _enabled = value),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _url,
                      label: l10n.settingsPushRelayUrl,
                      hint: l10n.settingsPushRelayUrlHint,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _token,
                      label: l10n.settingsPushToken,
                      hint: state.settings.hasToken
                          ? l10n.settingsPushTokenSaved
                          : l10n.settingsPushTokenHint,
                      obscure: true,
                    ),
                    if (state.error case final error?) ...[
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
                        FilledButton(
                          onPressed: state.saving ? null : () => _save(l10n),
                          child: Text(l10n.commonSave),
                        ),
                        OutlinedButton(
                          onPressed: state.saving ? null : () => _test(l10n),
                          child: Text(l10n.settingsPushTest),
                        ),
                        if (state.settings.hasToken)
                          TextButton(
                            onPressed: state.saving
                                ? null
                                : () => _clearToken(l10n),
                            child: Text(l10n.settingsPushClearToken),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
