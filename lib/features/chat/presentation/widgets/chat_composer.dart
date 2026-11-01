import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/composer_input.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Композер: поле ввода, вложения, настройки чата и отправка в одной карточке.
///
/// Настройки живут внизу карточки, рядом с кнопкой отправки: они влияют на следующий шаг,
/// поэтому их логично менять там же, где пишут сообщение. Во время работы кнопка отправки
/// становится очередью, а рядом появляется остановка.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.state,
    required this.controller,
    required this.attachments,
    required this.dragging,
    required this.settings,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onSubmit,
    required this.onStop,
    super.key,
  });

  final ChatState state;
  final TextEditingController controller;
  final List<AttachmentRef> attachments;
  final bool dragging;

  /// Строка настроек чата (хост, папка, модель, политика, контекст).
  final Widget settings;
  final VoidCallback onAttach;
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
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
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
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (attachments.isNotEmpty) ...[
                      Align(
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
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: ComposerInput(
                            controller: controller,
                            hint: l10n.composerHint,
                            busy: busy,
                            onSubmit: onSubmit,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        if (busy) ...[
                          IconButton.filledTonal(
                            visualDensity: VisualDensity.compact,
                            tooltip: l10n.composerStop,
                            icon: const Icon(Icons.stop),
                            onPressed: onStop,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        _SendButton(
                          controller: controller,
                          hasAttachments: attachments.isNotEmpty,
                          tooltip: l10n.composerSend,
                          onPressed: () => onSubmit(false),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: l10n.composerAttach,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.attach_file),
                          onPressed: onAttach,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(child: settings),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.md,
                top: AppSpacing.xs,
                right: AppSpacing.md,
              ),
              child: Text(
                state.isRunning ? l10n.composerHintBusy : l10n.composerHintIdle,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
