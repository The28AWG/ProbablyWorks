import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/util/text_clip.dart';

/// Настройки дополнительного провайдера llama.cpp.
///
/// Адрес, ключ и статус хранятся в настройках агента; ключ — в `SecretStore`.
/// Модели llama.cpp попадают в общий каталог с префиксом `llamacpp:`.
class LlamaCppSection extends StatefulWidget {
  const LlamaCppSection({required this.state, required this.cubit, super.key});

  final SettingsState state;
  final SettingsCubit cubit;

  @override
  State<LlamaCppSection> createState() => _LlamaCppSectionState();
}

class _LlamaCppSectionState extends State<LlamaCppSection> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _baseUrlFocus = FocusNode();
  final _apiKeyFocus = FocusNode();
  String? _baseUrlError;
  bool _replacingKey = false;

  @override
  void initState() {
    super.initState();
    _baseUrl.text = widget.state.catalog.llamaCpp.baseUrl;
  }

  @override
  void didUpdateWidget(covariant LlamaCppSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final saved = widget.state.catalog.llamaCpp.baseUrl;
    if (oldWidget.state.catalog.llamaCpp.baseUrl != saved &&
        !_baseUrlFocus.hasFocus) {
      _baseUrl.text = saved;
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _baseUrlFocus.dispose();
    _apiKeyFocus.dispose();
    super.dispose();
  }

  /// Адрес должен быть http(s)-URL с хостом: иначе сервер не опросить.
  bool _isValidBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Future<void> _saveBaseUrl(AppLocalizations l10n) async {
    final value = _baseUrl.text.trim();
    if (!_isValidBaseUrl(value)) {
      setState(() => _baseUrlError = l10n.settingsLlamaCppBaseUrlInvalid);
      return;
    }
    setState(() => _baseUrlError = null);
    await widget.cubit.saveLlamaCppBaseUrl(value);
  }

  Future<void> _saveKey() async {
    final value = _apiKey.text.trim();
    if (value.isEmpty) return;
    await widget.cubit.saveLlamaCppApiKey(value);
    if (!mounted) return;
    _apiKey.clear();
    setState(() => _replacingKey = false);
  }

  void _cancelReplace() {
    _apiKey.clear();
    setState(() => _replacingKey = false);
  }

  Future<void> _deleteKey(AppLocalizations l10n) async {
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.settingsLlamaCppApiKeyDeleteTitle,
      message: l10n.settingsLlamaCppApiKeyDeleteBody,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.settingsLlamaCppApiKeyDelete,
      destructive: true,
    );
    if (!confirmed) return;
    await widget.cubit.deleteLlamaCppApiKey();
  }

  Future<void> _check() async {
    await widget.cubit.refreshLlamaCpp();
    await widget.cubit.refreshModels();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = widget.state.catalog.llamaCpp;
    final showMask = status.apiKeySet && !_replacingKey;
    final loading = widget.state.catalog.loading;
    return AppSection(
      title: l10n.settingsLlamaCppTitle,
      description: l10n.settingsLlamaCppDescription,
      children: [
        AppChoiceGroup<bool>(
          options: [
            AppChoiceOption(
              value: true,
              title: l10n.settingsLlamaCppEnabledOn,
              subtitle: l10n.settingsLlamaCppEnabledHint,
              icon: const Icon(Icons.play_arrow_outlined),
            ),
            AppChoiceOption(
              value: false,
              title: l10n.settingsLlamaCppEnabledOff,
              subtitle: l10n.settingsLlamaCppEnabledHint,
              icon: const Icon(Icons.pause_outlined),
            ),
          ],
          selected: status.enabled,
          onChanged: widget.cubit.setLlamaCppEnabled,
        ),
        SettingsFormRow(
          title: l10n.settingsLlamaCppBaseUrl,
          description: l10n.settingsLlamaCppHint,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.verified_outlined),
                tooltip: l10n.settingsLlamaCppCheck,
                onPressed: loading ? null : _check,
              ),
              IconButton.filled(
                icon: const Icon(Icons.save_outlined),
                tooltip: l10n.settingsLlamaCppSave,
                onPressed: () => _saveBaseUrl(l10n),
              ),
            ],
          ),
          child: AppTextField(
            controller: _baseUrl,
            focusNode: _baseUrlFocus,
            hint: l10n.settingsLlamaCppBaseUrlHint,
            prefixIcon: Icons.dns_outlined,
            error: _baseUrlError,
            onSubmitted: (_) => _saveBaseUrl(l10n),
          ),
        ),
        SettingsFormRow(
          title: l10n.settingsLlamaCppApiKey,
          description: l10n.settingsLlamaCppKeyHint,
          trailing: showMask
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l10n.settingsApiKeyReplace,
                      onPressed: () => setState(() => _replacingKey = true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: l10n.settingsLlamaCppApiKeyDelete,
                      color: theme.colorScheme.error,
                      onPressed: () => _deleteKey(l10n),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status.apiKeySet)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: l10n.commonCancel,
                        onPressed: _cancelReplace,
                      ),
                    IconButton.filled(
                      icon: const Icon(Icons.save_outlined),
                      tooltip: l10n.commonSave,
                      onPressed: _saveKey,
                    ),
                  ],
                ),
          child: AppTextField(
            controller: _apiKey,
            focusNode: _apiKeyFocus,
            readOnly: showMask,
            obscure: true,
            hint: showMask
                ? '•••• ${status.apiKeyTail}'
                : l10n.settingsLlamaCppApiKeyHint,
            prefixIcon: Icons.key_outlined,
          ),
        ),
        if (!status.enabled)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.info,
            icon: Icons.pause_outlined,
            message: l10n.settingsLlamaCppDisabled,
          )
        else if (status.available)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.success,
            icon: Icons.check_circle_outline,
            message: l10n.settingsLlamaCppAvailable(
              '${status.modelCount ?? 0}',
            ),
          )
        else if (status.error != null)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.danger,
            icon: Icons.error_outline,
            message: l10n.settingsLlamaCppError(
              TextClip.headTail(status.error!, maxChars: 300),
            ),
          )
        else if (status.checkedAt == null)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.info,
            icon: Icons.info_outline,
            message: l10n.settingsLlamaCppCheckHint,
          )
        else
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.warning,
            icon: Icons.warning_amber_outlined,
            message: l10n.settingsLlamaCppUnavailable,
          ),
        if (status.checkedAt != null)
          Text(
            l10n.settingsLlamaCppCheckedAt(
              formatModelSyncTime(status.checkedAt!),
            ),
            style: theme.textTheme.labelSmall,
          ),
      ],
    );
  }
}
