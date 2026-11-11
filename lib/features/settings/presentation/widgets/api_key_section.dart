import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/features/settings/presentation/widgets/api_key_info_card.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Блок «API-ключ» вкладки «Аккаунт». Одна строка: поле и иконки действий в одну линию.
///
/// Установленный ключ показан тем же полем в режиме «только чтение» с маской из трёх последних
/// символов, поэтому высота строки одинакова в обоих состояниях. Действия — иконки с подсказками:
/// проверить, заменить, удалить с подтверждением; в режиме ввода — отмена (если ключ уже есть) и
/// сохранить. Черновик ключа и режим замены живут здесь, а не на странице: полный ключ не должен
/// попадать в состояние экрана.
class ApiKeySection extends StatefulWidget {
  const ApiKeySection({required this.state, required this.cubit, super.key});

  final SettingsState state;
  final SettingsCubit cubit;

  @override
  State<ApiKeySection> createState() => _ApiKeySectionState();
}

class _ApiKeySectionState extends State<ApiKeySection> {
  final _apiKey = TextEditingController();

  /// Ключ задан, но пользователь нажал «Заменить»: показываем поле ввода вместо маски.
  bool _replacingKey = false;

  @override
  void dispose() {
    _apiKey.dispose();
    super.dispose();
  }

  /// Ключ очищается из поля и закрывает режим замены только при успехе: при ошибке поле остаётся с текстом.
  Future<void> _save() async {
    await widget.cubit.saveApiKey(_apiKey.text);
    if (!mounted || widget.cubit.state.keyError != null) return;
    _apiKey.clear();
    setState(() => _replacingKey = false);
  }

  void _cancelReplace() {
    _apiKey.clear();
    setState(() => _replacingKey = false);
  }

  /// Удаление только после подтверждения: ключ нужен для работы всех экранов.
  Future<void> _delete(AppLocalizations l10n) async {
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.settingsApiKeyDeleteTitle,
      message: l10n.settingsApiKeyDeleteBody,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.settingsApiKeyDelete,
      destructive: true,
    );
    if (!confirmed) return;
    await widget.cubit.deleteApiKey();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = widget.state;
    final cubit = widget.cubit;
    final showMask = state.apiKeySet && !_replacingKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: SettingsFormRow(
            title: l10n.settingsApiKey,
            description: state.apiKeySet
                ? l10n.settingsApiKeySet
                : l10n.settingsApiKeyNotSet,
            trailing: showMask
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.verified_outlined),
                        tooltip: l10n.settingsApiKeyCheck,
                        onPressed: state.keyInfoLoading
                            ? null
                            : cubit.refreshKeyInfo,
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: l10n.settingsApiKeyReplace,
                        onPressed: () => setState(() => _replacingKey = true),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.settingsApiKeyDelete,
                        color: theme.colorScheme.error,
                        onPressed: () => _delete(l10n),
                      ),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.apiKeySet)
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: l10n.commonCancel,
                          onPressed: _cancelReplace,
                        ),
                      IconButton.filled(
                        icon: const Icon(Icons.save_outlined),
                        tooltip: l10n.commonSave,
                        onPressed: _save,
                      ),
                    ],
                  ),
            child: AppTextField(
              controller: _apiKey,
              readOnly: showMask,
              obscure: true,
              hint: showMask ? '•••• ${state.apiKeyTail}' : l10n.apiKeyHint,
              prefixIcon: Icons.key_outlined,
            ),
          ),
        ),
        if (state.keyError != null) ...[
          const SizedBox(height: AppSpacing.md),
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.danger,
            icon: Icons.error_outline,
            message: l10n.commonError(
              TextClip.headTail(state.keyError!, maxChars: 300),
            ),
          ),
        ],
        if (state.apiKeySet) ...[
          const SizedBox(height: AppSpacing.md),
          ApiKeyInfoCard(
            info: state.keyInfo,
            loading: state.keyInfoLoading,
            error: state.keyInfoError,
            onRetry: cubit.refreshKeyInfo,
          ),
        ],
      ],
    );
  }
}
