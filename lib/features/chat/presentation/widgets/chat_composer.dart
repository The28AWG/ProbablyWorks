import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/features/chat/presentation/widgets/composer_input.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Композер: поле ввода, вложения, настройки чата и отправка в одной карточке.
///
/// Всё, что меняет поведение следующего шага, собрано в меню «+»: прикрепление файла, рабочая папка
/// и режим выполнения. Внизу карточки одна строка: «+», чипы настроек, остановка и отправка.
/// Во время работы кнопка отправки становится очередью, а рядом появляется остановка.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.state,
    required this.controller,
    required this.attachments,
    required this.dragging,
    required this.settings,
    required this.workspace,
    required this.policy,
    required this.onAttach,
    required this.onPickWorkspace,
    required this.onPolicySelected,
    required this.onRemoveAttachment,
    required this.onSubmit,
    required this.onStop,
    super.key,
  });

  final ChatState state;
  final TextEditingController controller;
  final List<AttachmentRef> attachments;
  final bool dragging;

  /// Строка настроек чата (хост, папка, модель, контекст).
  final Widget settings;

  /// Рабочая папка чата; null — не назначена.
  final String? workspace;
  final PolicyMode policy;
  final VoidCallback onAttach;
  final VoidCallback onPickWorkspace;
  final ValueChanged<PolicyMode> onPolicySelected;
  final void Function(int index) onRemoveAttachment;
  final void Function(bool sendNow) onSubmit;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final busy = state.isRunning;
    return ChatColumn.fixed(
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: AppRadius.lgAll,
            border: Border.all(
              color: dragging ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ChatReveal(
                  open: attachments.isNotEmpty,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (var i = 0; i < attachments.length; i++)
                            InputChip(
                              avatar: Icon(
                                attachments[i].mode == AttachmentMode.attach
                                    ? Icons.description_outlined
                                    : Icons.folder_open,
                                size: 16,
                              ),
                              label: Text(attachments[i].name),
                              onDeleted: () => onRemoveAttachment(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: AppDurations.fast,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: ComposerInput(
                    controller: controller,
                    hint: l10n.composerHint,
                    busy: busy,
                    onSubmit: onSubmit,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    _PlusMenu(
                      workspace: workspace,
                      running: busy,
                      policy: policy,
                      onAttach: onAttach,
                      onPickWorkspace: onPickWorkspace,
                      onPolicySelected: onPolicySelected,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(child: settings),
                    ChatMorph(
                      child: busy
                          ? Row(
                              key: const ValueKey('stop'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton.filledTonal(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: l10n.composerStop,
                                  icon: const Icon(Icons.stop),
                                  onPressed: onStop,
                                ),
                                const SizedBox(width: AppSpacing.xs),
                              ],
                            )
                          : const SizedBox.shrink(key: ValueKey('no-stop')),
                    ),
                    _SendButton(
                      controller: controller,
                      hasAttachments: attachments.isNotEmpty,
                      tooltip: l10n.composerSend,
                      onPressed: () => onSubmit(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Меню «+»: прикрепление файла, рабочая папка и режим выполнения.
///
/// Кнопка окрашивается предупреждением, пока включено «Авто-подтверждение»: режим без запросов
/// должен быть заметен, даже когда строка настроек скрыла его чип.
class _PlusMenu extends StatelessWidget {
  const _PlusMenu({
    required this.workspace,
    required this.running,
    required this.policy,
    required this.onAttach,
    required this.onPickWorkspace,
    required this.onPolicySelected,
  });

  final String? workspace;
  final bool running;
  final PolicyMode policy;
  final VoidCallback onAttach;
  final VoidCallback onPickWorkspace;
  final ValueChanged<PolicyMode> onPolicySelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final folder = workspaceFolderName(workspace);
    final yolo = policy == PolicyMode.yolo;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.attach_file),
          onPressed: onAttach,
          child: Text(l10n.composerAttach),
        ),
        // Папку нельзя менять во время работы: место выполнения фиксировано.
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_outlined),
          onPressed: running ? null : onPickWorkspace,
          child: SizedBox(
            width: 260,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.chatWorkspaceLabel),
                if (folder != null)
                  Text(
                    folder,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
        SubmenuButton(
          leadingIcon: Icon(_policyIcon(policy)),
          menuChildren: [
            _policyItem(
              context,
              mode: PolicyMode.ask,
              title: l10n.policyAsk,
              hint: l10n.policyAskHint,
              icon: Icons.shield_outlined,
            ),
            _policyItem(
              context,
              mode: PolicyMode.yolo,
              title: l10n.policyYolo,
              hint: l10n.policyYoloHint,
              icon: Icons.bolt_outlined,
            ),
          ],
          child: Text(l10n.composerModeLabel),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        tooltip: l10n.composerAddTooltip,
        visualDensity: VisualDensity.compact,
        color: yolo ? toneColors(context, AppTone.warning).foreground : null,
        icon: const Icon(Icons.add),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  MenuItemButton _policyItem(
    BuildContext context, {
    required PolicyMode mode,
    required String title,
    required String hint,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return MenuItemButton(
      leadingIcon: Icon(icon),
      trailingIcon: mode == policy ? const Icon(Icons.check, size: 18) : null,
      onPressed: () => onPolicySelected(mode),
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _policyIcon(PolicyMode mode) => switch (mode) {
    PolicyMode.ask => Icons.shield_outlined,
    PolicyMode.yolo => Icons.bolt_outlined,
  };
}

/// Кнопка отправки неактивна, пока отправлять нечего: пустое поле и без вложений.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.controller,
    required this.hasAttachments,
    required this.tooltip,
    required this.onPressed,
  });

  final TextEditingController controller;
  final bool hasAttachments;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final canSend = hasAttachments || value.text.trim().isNotEmpty;
          return IconButton.filled(
            visualDensity: VisualDensity.compact,
            tooltip: tooltip,
            icon: const Icon(Icons.arrow_upward),
            onPressed: canSend ? onPressed : null,
          );
        },
      );
}

/// Подсветка при перетаскивании файлов в окно чата.
class ChatDropOverlay extends StatelessWidget {
  const ChatDropOverlay({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: DashedBorder(
        color: scheme.primary,
        child: ColoredBox(
          color: scheme.primary.withValues(alpha: 0.06),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, size: 32, color: scheme.primary),
                const SizedBox(height: AppSpacing.sm),
                Text(label, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
