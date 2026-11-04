import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:probably_works/agent/attachments/attachment_loader.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/live_output_bus.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_attention_dock.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_column.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_context_dialog.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_welcome.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

/// Окно контекста, когда модель не сообщила свой лимит.
const _defaultContextLimit = 128000;

/// Один чат: шапка, лента, док внимания и композер с настройками.
/// Используется и в компактном маршруте, и в оболочке.
///
/// Блок и тело чата живут, пока открыт вид: смена [chatId] переключает чат на месте. Черновик у каждого
/// чата свой: при переключении поле ввода показывает черновик открываемого чата. Композер с настройками
/// держит прежние значения до прихода данных нового чата и заблокирован на время загрузки.
class ChatView extends StatefulWidget {
  const ChatView({
    this.chatId,
    this.seedChat,
    this.seedHosts = const [],
    this.onCreated,
    this.leading,
    super.key,
  });

  /// Открытый чат. Null — новый чат: стартовый экран, чат создастся при первой отправке.
  final String? chatId;

  /// Слева в шапке, в той же строке, что и название (кнопка «назад» на узком экране).
  final Widget? leading;

  /// Чат из уже загруженного списка: шапка и композер появляются в первом кадре, без скелета.
  /// Null — чат ещё не в списке (например, открыт по маршруту на узком экране): покажем скелет,
  /// если до этого ничего не открывали.
  final Chat? seedChat;
  final List<Host> seedHosts;

  /// Новый чат записан в БД после первой отправки. Владелец экрана переключает выбор на него.
  final ValueChanged<String>? onCreated;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  late final _bloc = ChatBloc(
    getIt<AgentHub>(),
    getIt<LiveOutputBus>(),
    getIt<ChatDraftStore>(),
    seedChat: widget.seedChat,
    seedHosts: widget.seedHosts,
    onChatCreated: (id) => widget.onCreated?.call(id),
  )..add(_openEvent(widget.chatId));

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final chatId = widget.chatId;
    if (chatId == oldWidget.chatId) return;
    // Новый чат, который только что записан после отправки: блок уже открыт на нём, второй раз не открываем.
    if (chatId != null && chatId == _bloc.state.chatId) return;
    _bloc.add(
      _openEvent(
        chatId,
        seedChat: widget.seedChat,
        seedHosts: widget.seedHosts,
      ),
    );
  }

  ChatEvent _openEvent(
    String? chatId, {
    Chat? seedChat,
    List<Host> seedHosts = const [],
  }) => chatId == null
      ? const ChatDraftOpened()
      : ChatOpened(chatId, seedChat: seedChat, seedHosts: seedHosts);

  @override
  void dispose() {
    unawaited(_bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
    value: _bloc,
    child: ChatBody(leading: widget.leading),
  );
}

/// Тело чата без создания блока: блок должен быть выше по дереву (см. [ChatView]).
class ChatBody extends StatefulWidget {
  const ChatBody({this.leading, super.key});

  /// См. [ChatView.leading].
  final Widget? leading;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  final _composer = TextEditingController();

  /// Композер переезжает между центром пустого чата и низом ленты. Ключ сохраняет его состояние при переезде.
  final _composerKey = GlobalKey();
  var _dragging = false;
  var _draftId = 0;

  @override
  void initState() {
    super.initState();
    // Поле сразу показывает черновик текущего чата. Слушатель подключаем после, чтобы не отправить его обратно.
    _composer.text = context.read<ChatBloc>().state.draft;
    _composer.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _composer.removeListener(_onTextChanged);
    _composer.dispose();
    super.dispose();
  }

  void _onTextChanged() =>
      context.read<ChatBloc>().add(ChatDraftEdited(_composer.text));

  /// Плотность считается по ширине области чата (без боковой панели), а не по окну: см. [ChatDensity].
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ChatDensityScope(
      density: ChatDensity.fromWidth(constraints.maxWidth),
      child: _body(context),
    ),
  );

  Widget _body(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocConsumer<ChatBloc, ChatState>(
      listenWhen: (previous, current) => previous.draftId != current.draftId,
      listener: _onChatState,
      builder: (context, state) {
        final chat = state.chat;
        // Без перехода: fade всего тела на каждом открытии рисует весь экран через saveLayer.
        // Стартовый кадр нового чата: блок ещё готовит пустой чат, спиннера и скелета нет.
        if (chat == null && state.chatId == null) {
          return _ChatBlankBody(leading: widget.leading);
        }
        // Без чата (нет в списке) — полный каркас. С чатом из списка шапка и композер настоящие,
        // а при загрузке ленты меняется только её область.
        if (chat == null) return _ChatLoadingBody(leading: widget.leading);
        final bloc = context.read<ChatBloc>();
        final fraction = state.promptTokens == null
            ? null
            : state.promptTokens! /
                  (state.contextLimit ?? _defaultContextLimit);
        // Пустой чат (в том числе новый): композер по центру под приветствием. Как только появилось
        // сообщение или ход начался, композер уходит вниз. Переход сохраняет состояние композера (фокус, текст).
        final empty =
            !state.loading &&
            !state.isRunning &&
            !state.messages.any((m) => m.role != MessageRole.tool);
        final composer = KeyedSubtree(
          key: _composerKey,
          // Во время загрузки чата настройки относятся к прежнему чату: меняются только после загрузки.
          // Фокус тоже снимаем: иначе текст набрался бы в поле, которое сейчас относится к прежнему чату.
          child: ExcludeFocus(
            excluding: state.loading,
            child: IgnorePointer(
              ignoring: state.loading,
              child: ChatComposer(
                state: state,
                centered: empty,
                controller: _composer,
                attachments: state.attachments,
                dragging: _dragging,
                workspace: chat.workspace,
                policy: chat.policyMode,
                onPickWorkspace: () => _pickWorkspace(bloc, chat),
                onPolicySelected: (mode) => bloc.add(ChatPolicyChanged(mode)),
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
                  // Спиннер только пока название модели неизвестно: сохранённое показываем сразу.
                  modelLoading:
                      state.catalog.initialLoading &&
                      !state.catalog.knowsName(state.effectiveModelId),
                  modelPending: state.modelPending,
                  onPickModel: () => _pickModel(bloc, state, chat),
                  contextFraction: fraction,
                  onOpenContext: () => _openContext(bloc),
                  running: state.isRunning,
                ),
                onAttach: _pickFiles,
                onRemoveAttachment: (index) =>
                    bloc.add(ChatAttachmentRemoved(index)),
                onSubmit: (sendNow) => _submit(bloc, sendNow: sendNow),
                onStop: () => bloc.add(const ChatStopped()),
              ),
            ),
          ),
        );
        // Перетаскивание есть только на десктопе (desktop_drop на мобильных не работает): там остаётся кнопка.
        final content = Stack(
          children: [
            Column(
              children: [
                _Header(
                  title: chat.title.isEmpty ? l10n.chatsNew : chat.title,
                  leading: widget.leading,
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: state.loading
                            ? const Center(child: CircularProgressIndicator())
                            : ChatTimeline(
                                state: state,
                                terminalFor: bloc.terminalFor,
                              ),
                      ),
                      if (empty)
                        Positioned.fill(
                          child: Center(
                            // Боковые отступы берутся у колонки, как у нижнего композера: иначе прокрутка
                            // добавляла бы второй отступ, и композер в пустом чате был бы заметно уже.
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.lg,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ChatColumn.fixed(
                                    context,
                                    ChatWelcome(
                                      hostLabel: hostLabelOf(
                                        state.hosts,
                                        chat.hostId,
                                        l10n,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.xl),
                                  composer,
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                ChatAttentionDock(state: state),
                if (!empty) composer,
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
        );
        if (!AppPlatform.current.supportsFileDrop) {
          return KeyedSubtree(key: const ValueKey('body'), child: content);
        }
        return DropTarget(
          key: const ValueKey('body'),
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: _onDragDone,
          child: content,
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

  /// Читает файлы и добавляет их в черновик. Текст уходит в сообщение, бинарные файлы — модели
  /// отдельной частью. Путь на диске в вложение не попадает. Отказы показываются сообщением.
  Future<void> _addFiles(List<String> paths) async {
    final bloc = context.read<ChatBloc>();
    final l10n = AppLocalizations.of(context);
    final limits = bloc.state.limits;
    final cacheDir = AppPlatform.current.isMobile
        ? (await getTemporaryDirectory()).path
        : null;
    var room = limits.attachmentsPerMessage - bloc.state.attachments.length;
    final items = <AttachmentRef>[];
    final refused = <String>[];
    for (final path in paths) {
      if (room <= 0) {
        refused.add(l10n.attachLimitReached(limits.attachmentsPerMessage));
        break;
      }
      final name = path.split(RegExp(r'[\\/]')).last;
      final result = await loadAttachment(
        path,
        maxBytes: limits.attachmentMaxBytes,
        removeAfterReadUnder: cacheDir,
      );
      final ref = result.ref;
      if (ref == null) {
        refused.add(_problemText(l10n, name, result.problem!, limits));
        continue;
      }
      final mime = ref.mimeType;
      if (!_modelAccepts(bloc, mime)) {
        refused.add(l10n.attachModelNoFile(name, mime!));
        continue;
      }
      items.add(ref);
      room--;
    }
    // Чат могли закрыть, пока читались файлы: тогда блок уже не принимает события.
    if (!mounted) return;
    if (items.isNotEmpty) bloc.add(ChatAttachmentsAdded(items));
    if (refused.isNotEmpty) AppSnackBar.show(context, refused.join('\n'));
  }

  String _problemText(
    AppLocalizations l10n,
    String name,
    AttachmentProblem problem,
    AppLimits limits,
  ) => switch (problem) {
    AttachmentProblem.tooLarge => l10n.attachTooLarge(
      name,
      limits.attachmentMaxBytes,
    ),
    AttachmentProblem.unreadable => l10n.attachUnreadable(name),
    AttachmentProblem.unsupportedType => l10n.attachUnsupportedType(name),
  };

  /// Бинарный файл (mime задан) принимает только модель с нужной модальностью; текст принимает любая.
  bool _modelAccepts(ChatBloc bloc, String? mime) {
    if (mime == null) return true;
    final model = bloc.state.effectiveModelId;
    return model != null && bloc.state.catalog.acceptsFile(model, mime);
  }

  /// Перед отправкой: файлы без содержимого (после перезапуска) надо прикрепить заново,
  /// бинарные файлы — только моделью, которая их принимает.
  bool _attachmentsReady(ChatBloc bloc, List<AttachmentRef> attachments) {
    final l10n = AppLocalizations.of(context);
    for (final attachment in attachments) {
      if (!attachment.hasContent) {
        AppSnackBar.show(context, l10n.attachNeedReattach(attachment.name));
        return false;
      }
      final mime = attachment.mimeType;
      if (!_modelAccepts(bloc, mime)) {
        AppSnackBar.show(
          context,
          l10n.attachModelNoFile(attachment.name, mime!),
        );
        return false;
      }
    }
    return true;
  }

  void _submit(ChatBloc bloc, {required bool sendNow}) {
    // Пока чат загружается, сообщение ушло бы в чат, который ещё не открыт: текст остаётся в поле.
    if (bloc.state.loading) return;
    final text = _composer.text;
    final attachments = bloc.state.attachments;
    if (text.trim().isEmpty && attachments.isEmpty) return;
    if (!_attachmentsReady(bloc, attachments)) return;
    bloc.add(ChatSubmitted(text, attachments: attachments, sendNow: sendNow));
    // Очистка поля попадает в блок через слушатель и обнуляет черновик этого чата.
    _composer.clear();
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

/// Пустой экран нового чата до готовности блока: только заголовок, без спиннера и заглушек.
class _ChatBlankBody extends StatelessWidget {
  const _ChatBlankBody({this.leading});

  final Widget? leading;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Header(title: AppLocalizations.of(context).chatsNew, leading: leading),
      const Spacer(),
    ],
  );
}

/// Каркас чата до загрузки: шапка-заглушка, спиннер в ленте и скелет композера.
/// Шапка, лента и композер занимают те же места и размеры, что и в готовом чате.
class _ChatLoadingBody extends StatelessWidget {
  const _ChatLoadingBody({this.leading});

  final Widget? leading;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Header(title: null, leading: leading),
      Expanded(child: Center(child: CircularProgressIndicator())),
      ComposerSkeleton(),
    ],
  );
}

/// Шапка чата: название и, на узком экране, кнопка «назад» слева. Ни одного управляющего элемента:
/// всё, что меняет поведение агента, находится в композере.
/// Без названия (null) показывает заглушку той же высоты, что и текст.
class _Header extends StatelessWidget {
  const _Header({required this.title, this.leading});

  final String? title;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = this.title;
    return ChatColumn.fixed(
      context,
      Padding(
        padding: const EdgeInsets.only(
          top: AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
        child: Row(
          children: [
            ?leading,
            Expanded(
              child: title == null
                  ? _TitlePlaceholder(style: theme.textTheme.titleMedium)
                  : AnimatedSwitcher(
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

/// Заглушка названия: неразрывный пробел задаёт ту же высоту строки, что и настоящий текст.
/// Название в шапке центрируется (его обёртка AnimatedSwitcher ставит текст по центру), поэтому
/// заглушка тоже по центру: иначе при появлении названия шапка прыгает.
class _TitlePlaceholder extends StatelessWidget {
  const _TitlePlaceholder({required this.style});

  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Center(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.smAll,
      ),
      child: SizedBox(
        width: 160,
        child: Text('\u00A0', style: style, maxLines: 1),
      ),
    ),
  );
}
