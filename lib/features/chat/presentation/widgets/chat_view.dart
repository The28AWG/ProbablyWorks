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
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Содержимое одного чата: шапка, лента, композер. Используется и в узком экране, и справа в широком.
class ChatView extends StatelessWidget {
  const ChatView({required this.chatId, super.key});

  final String chatId;

  @override
  Widget build(BuildContext context) => BlocProvider(
    key: ValueKey(chatId),
    create: (_) =>
        ChatBloc(getIt<AgentHub>(), getIt<LiveOutputBus>())
          ..add(ChatOpened(chatId)),
    child: const _ChatBody(),
  );
}

class _ChatBody extends StatefulWidget {
  const _ChatBody();

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  final _composer = TextEditingController();
  final _workspace = TextEditingController();
  final _attachments = <AttachmentRef>[];
  var _dragging = false;
  var _draftId = 0;

  @override
  void dispose() {
    _composer.dispose();
    _workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocConsumer<ChatBloc, ChatState>(
      listenWhen: (previous, current) =>
          previous.chat?.workspace != current.chat?.workspace ||
          previous.draftId != current.draftId,
      listener: _onChatState,
      builder: (context, state) {
        final chat = state.chat;
        if (state.loading || chat == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_workspace.text.isEmpty && chat.workspace != null) {
          _workspace.text = chat.workspace!;
        }
        return DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: _onDragDone,
          child: Column(
            children: [
              _Header(state: state, workspace: _workspace),
              if (state.trustNeeded) _TrustBanner(),
              if (state.failure != null)
                _FailureBanner(message: state.failure!),
              Expanded(child: ChatTimeline(state: state)),
              if (state.isRunning) _StatusStrip(state: state),
              _Composer(
                state: state,
                controller: _composer,
                attachments: _attachments,
                dragging: _dragging,
                onAttach: _pickFiles,
                onRemoveAttachment: (index) =>
                    setState(() => _attachments.removeAt(index)),
                onSubmit: (sendNow) => _submit(context, sendNow: sendNow),
                onStop: () => context.read<ChatBloc>().add(const ChatStopped()),
              ),
              if (_dragging)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.composerDropHint,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _onChatState(BuildContext context, ChatState state) {
    if (state.draftId != _draftId) {
      _draftId = state.draftId;
      _composer.text = state.draft;
      _composer.selection = TextSelection.collapsed(offset: state.draft.length);
    } else {
      _workspace.text = state.chat?.workspace ?? '';
    }
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

  void _submit(BuildContext context, {required bool sendNow}) {
    final text = _composer.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    context.read<ChatBloc>().add(
      ChatSubmitted(text, attachments: List.of(_attachments), sendNow: sendNow),
    );
    _composer.clear();
    setState(_attachments.clear);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.workspace});

  final ChatState state;
  final TextEditingController workspace;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chat = state.chat!;
    final bloc = context.read<ChatBloc>();
    final used = state.promptTokens;
    final limit = state.contextLimit ?? 128000;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownMenu<String>(
              key: ValueKey('host-${chat.hostId}-${state.hosts.length}'),
              width: 180,
              label: Text(l10n.chatHostLabel),
              initialSelection: chat.hostId,
              enabled: !state.isRunning,
              dropdownMenuEntries: [
                for (final h in state.hosts)
                  DropdownMenuEntry(
                    value: h.id,
                    label: h.isLocal ? l10n.hostLocalName : h.name,
                  ),
              ],
              onSelected: (value) => _onHostSelected(bloc, value),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.memory, size: 18),
              label: Text(
                _modelLabel(chat.model, state.models, l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: () => _pickModel(context, bloc, state, chat, l10n),
            ),
            SegmentedButton<PolicyMode>(
              segments: [
                ButtonSegment(
                  value: PolicyMode.ask,
                  label: Text(l10n.policyAsk),
                ),
                ButtonSegment(
                  value: PolicyMode.yolo,
                  label: Text(l10n.policyYolo),
                ),
              ],
              selected: {chat.policyMode},
              onSelectionChanged: (value) =>
                  bloc.add(ChatPolicyChanged(value.first)),
            ),
            SizedBox(
              width: 260,
              child: TextField(
                controller: workspace,
                decoration: InputDecoration(
                  labelText: l10n.chatWorkspaceLabel,
                  isDense: true,
                ),
                onSubmitted: (value) => bloc.add(
                  ChatWorkspaceChanged(
                    value.trim().isEmpty ? null : value.trim(),
                  ),
                ),
              ),
            ),
            if (used != null)
              SizedBox(
                width: 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.contextUsage(
                        _groupDigits(used),
                        _groupDigits(limit),
                      ),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    LinearProgressIndicator(
                      value: (used / limit).clamp(0, 1).toDouble(),
                    ),
                  ],
                ),
              ),
            if (used != null)
              TextButton.icon(
                icon: const Icon(Icons.compress, size: 18),
                label: Text(l10n.compactHistory),
                onPressed: state.isRunning
                    ? null
                    : () => bloc.add(const ChatCompactRequested()),
              ),
          ],
        ),
      ),
    );
  }

  void _onHostSelected(ChatBloc bloc, String? value) {
    if (value != null) bloc.add(ChatHostChanged(value));
  }

  Future<void> _pickModel(
    BuildContext context,
    ChatBloc bloc,
    ChatState state,
    Chat chat,
    AppLocalizations l10n,
  ) async {
    final picked = await showModelPickerDialog(
      context,
      models: state.models,
      pinned: state.pinnedModels,
      currentId: chat.model,
      onTogglePin: (id) => bloc.add(ChatModelPinToggled(id)),
    );
    if (picked == null || picked.id == chat.model || !context.mounted) return;
    bloc.add(ChatModelChanged(picked));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.chatModelSwitched(picked.name))),
    );
  }

  static String _modelLabel(
    String? id,
    List<LlmModelInfo> models,
    AppLocalizations l10n,
  ) {
    if (id == null || id.isEmpty) return l10n.chatModelLabel;
    for (final model in models) {
      if (model.id == id) return model.name;
    }
    return id;
  }

  static String _groupDigits(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Однострочная полоса текущего шага агента: думает, выполняет команды, ждёт approve или ответа.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.state});

  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final runs = state.runs;
    var foreground = 0;
    var background = 0;
    var waitingApproval = state.approvals.isNotEmpty;
    var waitingUser = state.questions.isNotEmpty;
    for (final run in runs) {
      if (run.status == ToolRunStatus.waitingApproval) waitingApproval = true;
      if (run.status == ToolRunStatus.waitingUser) waitingUser = true;
      if (run.status == ToolRunStatus.backgroundRunning) {
        background++;
      } else if (run.status == ToolRunStatus.running) {
        foreground++;
      }
    }
    final primary = switch ((waitingApproval, waitingUser, foreground)) {
      (true, _, _) => l10n.statusWaitingApproval,
      (_, true, _) => l10n.statusWaitingUser,
      (_, _, > 0) => l10n.statusRunningCommands(foreground),
      _ =>
        background > 0
            ? l10n.statusBackgroundCommands(background)
            : l10n.statusThinking,
    };
    final text = foreground > 0 && background > 0
        ? '$primary · ${l10n.statusBackgroundCommands(background)}'
        : primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrustBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 8),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        title: Text(l10n.trustTitle),
        subtitle: Text(l10n.trustBody),
        trailing: FilledButton(
          onPressed: () =>
              context.read<ChatBloc>().add(const ChatWorkspaceTrusted()),
          child: Text(l10n.trustAction),
        ),
      ),
    );
  }
}

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 8),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.error_outline, color: scheme.onErrorContainer),
        title: Text(
          l10n.commonError(TextClip.headTail(message, maxChars: 400)),
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.state,
    required this.controller,
    required this.attachments,
    required this.dragging,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onSubmit,
    required this.onStop,
  });

  final ChatState state;
  final TextEditingController controller;
  final List<AttachmentRef> attachments;
  final bool dragging;
  final VoidCallback onAttach;
  final void Function(int index) onRemoveAttachment;
  final void Function(bool sendNow) onSubmit;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final busy = state.isRunning;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: dragging
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachments.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
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
          LayoutBuilder(
            builder: (context, constraints) {
              // На узком окне кнопки становятся иконками, чтобы строка Stop/Send не переполнялась.
              final narrow = constraints.maxWidth < 620;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: l10n.composerAttach,
                    icon: const Icon(Icons.attach_file),
                    onPressed: onAttach,
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 8,
                      decoration: InputDecoration(
                        hintText: l10n.composerHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (busy) ...[
                    if (narrow)
                      IconButton(
                        tooltip: l10n.composerStop,
                        icon: const Icon(Icons.stop),
                        onPressed: onStop,
                      )
                    else
                      OutlinedButton.icon(
                        icon: const Icon(Icons.stop),
                        label: Text(l10n.composerStop),
                        onPressed: onStop,
                      ),
                    const SizedBox(width: 8),
                    if (narrow)
                      IconButton(
                        tooltip: l10n.composerSendNow,
                        icon: const Icon(Icons.bolt),
                        onPressed: () => onSubmit(true),
                      )
                    else
                      OutlinedButton(
                        onPressed: () => onSubmit(true),
                        child: Text(l10n.composerSendNow),
                      ),
                    const SizedBox(width: 8),
                    if (narrow)
                      IconButton.filled(
                        tooltip: l10n.composerSend,
                        icon: const Icon(Icons.send),
                        onPressed: () => onSubmit(false),
                      )
                    else
                      FilledButton(
                        onPressed: () => onSubmit(false),
                        child: Text(l10n.composerSend),
                      ),
                  ] else if (narrow)
                    IconButton.filled(
                      tooltip: l10n.composerSend,
                      icon: const Icon(Icons.send),
                      onPressed: () => onSubmit(false),
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.send),
                      label: Text(l10n.composerSend),
                      onPressed: () => onSubmit(false),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
