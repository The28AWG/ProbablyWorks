import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:probably_works/features/settings/presentation/widgets/api_key_info_card.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Карточка LLM-провайдера в настройках.
///
/// Рисуется только по [LlmProviderDescriptor] и [LlmProviderStatus]:
/// включение, адрес, ключ, проверка и маска. Провайдер-специфичных веток
/// здесь нет, поэтому третий провайдер появляется без правок этого файла.
class ProviderSection extends StatefulWidget {
  const ProviderSection({
    required this.descriptor,
    required this.status,
    required this.loading,
    required this.error,
    required this.onCheck,
    required this.onEnabledChanged,
    required this.onBaseUrlSaved,
    required this.onApiKeySaved,
    required this.onApiKeyDeleted,
    this.modelCount,
    super.key,
  });

  final LlmProviderDescriptor descriptor;
  final LlmProviderStatus status;

  /// Запрос проверки или сохранения в полёте.
  final bool loading;

  /// Ошибка сохранения; ошибка проверки приходит в [LlmProviderStatus.error].
  final String? error;

  final VoidCallback onCheck;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String> onBaseUrlSaved;

  /// Возвращает true, если ключ принят: тогда поле очищается.
  final Future<bool> Function(String key) onApiKeySaved;

  final VoidCallback onApiKeyDeleted;

  /// Количество моделей из каталога: точнее, чем счётчик последней проверки.
  final int? modelCount;

  @override
  State<ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends State<ProviderSection> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _baseUrlFocus = FocusNode();
  final _apiKeyFocus = FocusNode();
  String? _baseUrlError;
  bool _replacingKey = false;

  @override
  void initState() {
    super.initState();
    _baseUrl.text = _baseUrlOf(widget.status, widget.descriptor);
  }

  @override
  void didUpdateWidget(covariant ProviderSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final saved = _baseUrlOf(widget.status, widget.descriptor);
    if (saved != _baseUrlOf(oldWidget.status, oldWidget.descriptor) &&
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

  static String _baseUrlOf(
    LlmProviderStatus status,
    LlmProviderDescriptor descriptor,
  ) => status.baseUrl ?? descriptor.defaultBaseUrl ?? '';

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
      setState(() => _baseUrlError = l10n.providerBaseUrlInvalid);
      return;
    }
    setState(() => _baseUrlError = null);
    widget.onBaseUrlSaved(value);
  }

  Future<void> _saveKey() async {
    final value = _apiKey.text.trim();
    if (value.isEmpty) return;
    final accepted = await widget.onApiKeySaved(value);
    if (!mounted || !accepted) return;
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
      title: l10n.providerApiKeyDeleteTitle(widget.descriptor.label),
      message: l10n.providerApiKeyDeleteBody(widget.descriptor.label),
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.providerApiKeyDelete,
      destructive: true,
    );
    if (!confirmed) return;
    widget.onApiKeyDeleted();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final descriptor = widget.descriptor;
    final status = widget.status;
    final showMask = status.apiKeySet && !_replacingKey;
    final modelCount = widget.modelCount ?? status.modelCount ?? 0;
    return AppSection(
      title: descriptor.label,
      description: l10n.providerDescription,
      children: [
        if (descriptor.supportsEnabledToggle)
          AppChoiceGroup<bool>(
            options: [
              AppChoiceOption(
                value: true,
                title: l10n.providerEnabledOn,
                subtitle: l10n.providerEnabledHint,
                icon: const Icon(Icons.play_arrow_outlined),
              ),
              AppChoiceOption(
                value: false,
                title: l10n.providerEnabledOff,
                subtitle: l10n.providerEnabledHint,
                icon: const Icon(Icons.pause_outlined),
              ),
            ],
            selected: status.enabled,
            onChanged: widget.onEnabledChanged,
          ),
        if (descriptor.supportsBaseUrl)
          SettingsFormRow(
            title: l10n.providerBaseUrl,
            description: l10n.providerBaseUrlHint,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.verified_outlined),
                  tooltip: l10n.providerCheck,
                  onPressed: widget.loading ? null : widget.onCheck,
                ),
                IconButton.filled(
                  icon: const Icon(Icons.save_outlined),
                  tooltip: l10n.commonSave,
                  onPressed: () => _saveBaseUrl(l10n),
                ),
              ],
            ),
            child: AppTextField(
              controller: _baseUrl,
              focusNode: _baseUrlFocus,
              hint: descriptor.defaultBaseUrl ?? l10n.providerBaseUrlHint,
              prefixIcon: Icons.dns_outlined,
              error: _baseUrlError,
              onSubmitted: (_) => _saveBaseUrl(l10n),
            ),
          ),
        if (descriptor.supportsApiKey)
          SettingsFormRow(
            title: l10n.providerApiKey,
            description: status.apiKeySet
                ? l10n.providerApiKeySet
                : l10n.providerApiKeyNotSet,
            trailing: showMask
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.verified_outlined),
                        tooltip: l10n.providerCheck,
                        onPressed: widget.loading ? null : widget.onCheck,
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: l10n.settingsApiKeyReplace,
                        onPressed: () => setState(() => _replacingKey = true),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.providerApiKeyDelete,
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
                  : descriptor.apiKeyExample ?? l10n.providerApiKeyHint,
              prefixIcon: Icons.key_outlined,
            ),
          ),
        if (descriptor.supportsKeyInfo)
          if (status.apiKeySet)
            ApiKeyInfoCard(
              info: status.keyInfo,
              loading: widget.loading,
              // Ошибку показывает общий баннер ниже: без этого она
              // дублировалась бы в карточке и в баннере.
              error: null,
              onRetry: widget.onCheck,
            ),
        _ProviderStatusBanner(
          descriptor: descriptor,
          status: status,
          error: widget.error ?? status.error,
          modelCount: modelCount,
        ),
        if (status.checkedAt != null)
          Text(
            l10n.providerCheckedAt(formatModelSyncTime(status.checkedAt!)),
            style: theme.textTheme.labelSmall,
          ),
      ],
    );
  }
}

/// Баннер состояния провайдера: выключен, доступен, ошибка или нет ответа.
class _ProviderStatusBanner extends StatelessWidget {
  const _ProviderStatusBanner({
    required this.descriptor,
    required this.status,
    required this.error,
    required this.modelCount,
  });

  final LlmProviderDescriptor descriptor;
  final LlmProviderStatus status;
  final String? error;
  final int modelCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final message = error;
    if (!status.enabled) {
      return AppBanner(
        margin: EdgeInsets.zero,
        tone: AppTone.info,
        icon: Icons.pause_outlined,
        message: l10n.providerDisabled(descriptor.label),
      );
    }
    if (descriptor.requiresApiKey && !status.apiKeySet) {
      return AppBanner(
        margin: EdgeInsets.zero,
        tone: AppTone.info,
        icon: Icons.key_outlined,
        message: l10n.providerKeyRequired,
      );
    }
    if (message != null) {
      return AppBanner(
        margin: EdgeInsets.zero,
        tone: AppTone.danger,
        icon: Icons.error_outline,
        message: l10n.providerError(TextClip.headTail(message, maxChars: 300)),
      );
    }
    if (status.available) {
      return AppBanner(
        margin: EdgeInsets.zero,
        tone: AppTone.success,
        icon: Icons.check_circle_outline,
        message: l10n.providerAvailable(modelCount),
      );
    }
    if (status.checkedAt == null) {
      return AppBanner(
        margin: EdgeInsets.zero,
        tone: AppTone.info,
        icon: Icons.info_outline,
        message: l10n.providerCheckHint,
      );
    }
    return AppBanner(
      margin: EdgeInsets.zero,
      tone: AppTone.warning,
      icon: Icons.warning_amber_outlined,
      message: l10n.providerUnavailable,
    );
  }
}
