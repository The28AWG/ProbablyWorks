import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/features/chat/presentation/widgets/composer_input.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Композер: поле ввода, вложения, настройки чата и отправка в одной карточке.
///
/// Всё, что меняет поведение следующего шага, собрано в меню «+»: прикрепление файла, рабочая папка
/// и режим выполнения. Внизу карточки одна строка: «+», строка настроек и одна кнопка действия справа.
/// Кнопка действия зависит от состояния: при тексте или вложениях это отправка (во время работы агента —
/// очередь), а при работе агента с пустым полем — остановка. Иначе справа ничего нет.
///
/// Та же карточка правит уже отправленное сообщение ([editing]): пузырь в ленте подменяется ею.
/// Остановки и отдельной отмены там нет — правку сворачивает уход фокуса в нижнее поле, закрытие
/// чата или Escape, а текст остаётся черновиком. Отправка переписывает историю.
/// [embedded] убирает обёртку колонки: в ленте колонку уже даёт родитель.
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
    this.onInputFocus,
    this.hint,
    this.editing = false,
    this.embedded = false,
    this.submitting = false,
    this.centered = false,
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

  /// Отправка; `sendNow` — Ctrl/Cmd+Enter во время работы агента (вперёд очереди).
  final void Function(bool sendNow) onSubmit;
  final VoidCallback onStop;

  /// Фокус поля ввода. Нижний композер сообщает им, что пользователь вернулся к новому сообщению.
  final ValueChanged<bool>? onInputFocus;

  /// Карточка заменяет пузырь пользователя. Кнопки остановки нет: ход в этот момент не идёт.
  final bool editing;

  /// Подсказка поля. Null — обычная подсказка нового сообщения.
  final String? hint;

  /// Карточка без [ChatColumn]: родитель уже ограничил ширину (пузырь в ленте).
  final bool embedded;

  /// Отправка уже ушла (диалог отката файлов). Кнопки правки не нажимаются второй раз.
  final bool submitting;

  /// Композер стоит по центру пустого чата. Там поле может вырасти вдвое больше (см. [ChatDensity.composerMaxLines]).
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final density = ChatDensityScope.of(context);
    final busy = state.isRunning;
    final card = Padding(
      padding: embedded
          ? const EdgeInsets.symmetric(vertical: AppSpacing.sm)
          : const EdgeInsets.only(bottom: AppSpacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: density.composerRadius,
          border: Border.all(
            color: dragging ? scheme.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Padding(
          padding: density.composerPadding,
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
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: AppLayout.attachmentChipMaxWidth,
                            ),
                            child: InputChip(
                              avatar: Icon(
                                attachments[i].mode == AttachmentMode.attach
                                    ? Icons.description_outlined
                                    : Icons.attach_file,
                                size: 16,
                              ),
                              label: Text(
                                attachments[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onDeleted: () => onRemoveAttachment(i),
                            ),
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
                  hint: hint ?? l10n.composerHint,
                  busy: busy,
                  loading: state.loading,
                  maxLines: density.composerMaxLines(centered: centered),
                  onSubmit: onSubmit,
                  onFocus: onInputFocus,
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
                  _ActionSlot(
                    controller: controller,
                    hasAttachments: attachments.isNotEmpty,
                    busy: busy,
                    submitting: submitting,
                    editing: editing,
                    sendTooltip: l10n.composerSend,
                    stopTooltip: l10n.composerStop,
                    onSend: () => onSubmit(false),
                    onStop: onStop,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (embedded) return card;
    return ChatColumn.fixed(context, card);
  }
}

/// Одна кнопка действия справа от строки настроек. Её состояние выбирается по полю и работе агента:
///
/// - есть текст или вложения: отправка (во время работы — очередь), стоп скрыт;
/// - поле пустое и агент работает: только стоп;
/// - поле пустое и агент не работает: ничего, место справа освобождается.
///
/// Правка сообщения ([editing]) показывает только отправку: остановки нет, отмена живёт снаружи
/// карточки. Отправка блокируется, пока правка уже ушла ([submitting]).
///
/// Переход между состояниями плавный ([ChatMorph]). Ключи у кнопок обязательны, иначе смену не видно.
class _ActionSlot extends StatelessWidget {
  const _ActionSlot({
    required this.controller,
    required this.hasAttachments,
    required this.busy,
    required this.submitting,
    required this.editing,
    required this.sendTooltip,
    required this.stopTooltip,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool hasAttachments;
  final bool busy;
  final bool submitting;
  final bool editing;
  final String sendTooltip;
  final String stopTooltip;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final canSend = hasAttachments || value.text.trim().isNotEmpty;
          final showStop = !editing && !canSend && busy;
          final showSend = canSend;
          return ChatMorph(
            child: showSend
                ? IconButton.filled(
                    key: const ValueKey('send'),
                    visualDensity: VisualDensity.compact,
                    tooltip: sendTooltip,
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: submitting ? null : onSend,
                  )
                : showStop
                ? IconButton.filledTonal(
                    key: const ValueKey('stop'),
                    visualDensity: VisualDensity.compact,
                    tooltip: stopTooltip,
                    icon: const Icon(Icons.stop),
                    onPressed: onStop,
                  )
                : const SizedBox.shrink(key: ValueKey('none')),
          );
        },
      );
}

/// Каркас композера на время загрузки чата: та же карточка и те же высоты, что у [ChatComposer],
/// без управляющих элементов. Благодаря этому при появлении чата композер не сдвигается и не меняет
/// размер. Тест на совпадение размеров защищает эти константы.
class ComposerSkeleton extends StatelessWidget {
  const ComposerSkeleton({super.key});

  /// Высота поля ввода и строки кнопок готового композера (измерено).
  static const _inputHeight = 44.0;
  static const _buttonSize = 40.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.surfaceContainerHighest;
    return ChatColumn.fixed(
      context,
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: ChatDensityScope.of(context).composerRadius,
          ),
          child: Padding(
            padding: ChatDensityScope.of(context).composerPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: _inputHeight,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _Bar(width: 220, height: 14, color: fill),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                SizedBox(
                  height: _buttonSize,
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: _buttonSize,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: fill,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: _Bar(
                            width: 160,
                            height: 28,
                            color: fill,
                            radius: AppRadius.lgAll,
                          ),
                        ),
                      ),
                      // Место под кнопку действия: скелет держит ту же высоту строки, что и готовый композер.
                      SizedBox.square(
                        dimension: _buttonSize,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: fill,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Плашка-заглушка текста в скелетах: без анимации, чтобы не отвлекать на коротком ожидании.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.width,
    required this.height,
    required this.color,
    this.radius = AppRadius.smAll,
  });

  final double width;
  final double height;
  final Color color;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, borderRadius: radius),
    ),
  );
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
          child: Text(
            l10n.composerAttach,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
                Text(
                  l10n.chatWorkspaceLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (folder != null)
                  Text(
                    folder,
                    maxLines: 1,
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
            _PolicyMenuItem(
              mode: PolicyMode.ask,
              current: policy,
              title: l10n.policyAsk,
              hint: l10n.policyAskHint,
              icon: Icons.shield_outlined,
              onSelected: onPolicySelected,
            ),
            _PolicyMenuItem(
              mode: PolicyMode.yolo,
              current: policy,
              title: l10n.policyYolo,
              hint: l10n.policyYoloHint,
              icon: Icons.bolt_outlined,
              onSelected: onPolicySelected,
            ),
          ],
          child: Text(
            l10n.composerModeLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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

  static IconData _policyIcon(PolicyMode mode) => switch (mode) {
    PolicyMode.ask => Icons.shield_outlined,
    PolicyMode.yolo => Icons.bolt_outlined,
  };
}

/// Пункт подменю «Режим выполнения»: название, пояснение и отметка текущего режима.
class _PolicyMenuItem extends StatelessWidget {
  const _PolicyMenuItem({
    required this.mode,
    required this.current,
    required this.title,
    required this.hint,
    required this.icon,
    required this.onSelected,
  });

  final PolicyMode mode;
  final PolicyMode current;
  final String title;
  final String hint;
  final IconData icon;
  final ValueChanged<PolicyMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuItemButton(
      leadingIcon: Icon(icon),
      trailingIcon: mode == current ? const Icon(Icons.check, size: 18) : null,
      onPressed: () => onSelected(mode),
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
