import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_attention_dock.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_context_dialog.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

/// Окно контекста, когда модель не сообщила свой лимит.
const _defaultContextLimit = 128000;

/// Один чат: шапка, лента, док внимания и композер с настройками.
/// Используется и в компактном маршруте, и в оболочке.
class ChatView extends StatelessWidget {
  const ChatView({required this.chatId, super.key});

  final String chatId;

  @override
  Widget build(BuildContext context) => BlocProvider(
    key: ValueKey(chatId),
    create: (_) =>
        ChatBloc(getIt<AgentHub>(), getIt<LiveOutputBus>())
          ..add(ChatOpened(chatId)),
    child: const ChatBody(),
  );
}

/// Тело чата без создания блока: блок должен быть выше по дереву (см. [ChatView]).
class ChatBody extends StatefulWidget {
  const ChatBody({super.key});

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  final _composer = TextEditingController();
  final _attachments = <AttachmentRef>[];
  var _dragging = false;
  var _draftId = 0;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocConsumer<ChatBloc, ChatState>(
      listenWhen: (previous, current) => previous.draftId != current.draftId,
      listener: _onChatState,
      builder: (context, state) {
        final chat = state.chat;
        // Загрузка и тело чата сменяют друг друга плавно, а не мгновенно.
        if (state.loading || chat == null) {
          return AnimatedSwitcher(
            duration: AppDurations.normal,
            child: const Center(
              key: ValueKey('loading'),
              child: CircularProgressIndicator(),
            ),
          );
        }
        final bloc = context.read<ChatBloc>();
        final fraction = state.promptTokens == null
            ? null
            : state.promptTokens! /
                  (state.contextLimit ?? _defaultContextLimit);
        return AnimatedSwitcher(
          duration: AppDurations.normal,
          child: DropTarget(
            key: const ValueKey('body'),
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: _onDragDone,
            child: Stack(
              children: [
                Column(
                  children: [
                    _Header(
                      title: chat.title.isEmpty ? l10n.chatsNew : chat.title,
                    ),
                    Expanded(
                      child: ChatTimeline(
                        state: state,
                        terminalFor: context.read<ChatBloc>().terminalFor,
                      ),
                    ),
                    ChatAttentionDock(state: state),
                    ChatComposer(
                      state: state,
                      controller: _composer,
                      attachments: _attachments,
                      dragging: _dragging,
                      workspace: chat.workspace,
                      policy: chat.policyMode,
                      onPickWorkspace: () => _pickWorkspace(bloc, chat),
                      onPolicySelected: (mode) =>
                          bloc.add(ChatPolicyChanged(mode)),
                      settings: ChatMetaBar(
                        hosts: state.hosts,
                        hostId: chat.hostId,
                        onHostSelected: (id) => bloc.add(ChatHostChanged(id)),
                        workspace: chat.workspace,
                        onPickWorkspace: () => _pickWorkspace(bloc, chat),
                        modelLabel: _modelLabel(
                          state.effectiveModelId,
                          state.catalog,
                        ),
                        modelUnavailable: state.modelUnavailable,
                        modelLoading: state.catalog.initialLoading,
                        onPickModel: () => _pickModel(bloc, state, chat),
                        contextFraction: fraction,
                        onOpenContext: () => _openContext(bloc),
                        running: state.isRunning,
                      ),
                      onAttach: _pickFiles,
                      onRemoveAttachment: (index) =>
                          setState(() => _attachments.removeAt(index)),
                      onSubmit: (sendNow) => _submit(bloc, sendNow: sendNow),
                      onStop: () => bloc.add(const ChatStopped()),
                    ),
                  ],
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_dragging,
                    child: AnimatedOpacity(
                      opacity: _dragging ? 1 : 0,
                      duration: AppDurations.fast,
                      child: ChatDropOverlay(label: l10n.composerDropHint),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onChatState(BuildContext context, ChatState state) {
    if (state.draftId == _draftId) return;
    _draftId = state.draftId;
    _composer.text = state.draft;
    _composer.selection = TextSelection.collapsed(offset: state.draft.length);
  }

  void _onDragDone(DropDoneDetails details) {
    setState(() => _dragging = false);
    unawaited(_addFiles([for (final f in details.files) f.path]));
  }

  Future<void> _pickFiles() async {
    final files = await openFiles();
    await _addFiles([for (final f in files) f.path]);
  }

  /// Небольшие текстовые файлы идут в контекст (attach), остальные — путь (mention).
  Future<void> _addFiles(List<String> paths) async {
    final limits = context.read<ChatBloc>().state.limits;
    for (final path in paths) {
      if (_attachments.length >= limits.attachmentsPerMessage) break;
      final file = File(path);
      final name = path.split(Platform.pathSeparator).last;
      final size = await file.length();
      if (size <= limits.attachmentMaxBytes) {
        try {
          final content = await file.readAsString();
          if (!mounted) return;
          setState(
            () => _attachments.add(
              AttachmentRef(
                name: name,
                mode: AttachmentMode.attach,
                content: content,
                sizeBytes: size,
              ),
            ),
          );
          continue;
        } on FormatException {
          // Бинарный файл: передаём путь, агент прочитает его через инструменты.
        }
      }
      if (!mounted) return;
      setState(
        () => _attachments.add(
          AttachmentRef(
            name: name,
            mode: AttachmentMode.mention,
            path: path,
            sizeBytes: size,
          ),
        ),
      );
    }
  }

  void _submit(ChatBloc bloc, {required bool sendNow}) {
    final text = _composer.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    bloc.add(
      ChatSubmitted(text, attachments: List.of(_attachments), sendNow: sendNow),
    );
    _composer.clear();
    setState(_attachments.clear);
  }

  Future<void> _pickWorkspace(ChatBloc bloc, Chat chat) async {
    final l10n = AppLocalizations.of(context);
    final picked = await ConfirmDialog.prompt(
      context,
      title: l10n.chatWorkspaceLabel,
      hint: l10n.chatWorkspaceHint,
      initialText: chat.workspace ?? '',
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
    );
    if (picked == null || !mounted) return;
    final trimmed = picked.trim();
    bloc.add(ChatWorkspaceChanged(trimmed.isEmpty ? null : trimmed));
  }

  Future<void> _openContext(ChatBloc bloc) => showDialog<void>(
    context: context,
    builder: (_) => BlocProvider.value(
      value: bloc,
      child: BlocBuilder<ChatBloc, ChatState>(
        builder: (dialogContext, state) => ChatContextDialog(
          used: state.promptTokens,
          limit: state.contextLimit ?? _defaultContextLimit,
          running: state.isRunning,
          onCompact: () => bloc.add(const ChatCompactRequested()),
        ),
      ),
    ),
  );

  Future<void> _pickModel(ChatBloc bloc, ChatState state, Chat chat) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showModelPickerDialog(
      context,
      catalog: getIt<ModelCatalogService>(),
      pinned: state.pinnedModels,
      currentId: state.effectiveModelId,
      onTogglePin: (id) => bloc.add(ChatModelPinToggled(id)),
    );
    if (picked == null || picked.id == chat.model || !mounted) return;
    bloc.add(ChatModelChanged(picked));
    AppSnackBar.show(context, l10n.chatModelSwitched(picked.name));
  }

  /// Название модели для чипа; null — модель не выбрана ни в чате, ни в настройках.
  static String? _modelLabel(String? id, ModelCatalogState catalog) =>
      id == null ? null : catalog.nameOf(id);
}

/// Шапка чата: только название. Ни одного управляющего элемента:
/// всё, что меняет поведение агента, находится в композере.
class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ChatColumn.fixed(
      Padding(
        padding: const EdgeInsets.only(
          top: AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: AppDurations.fast,
                child: Text(
                  title,
                  key: ValueKey(title),
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
