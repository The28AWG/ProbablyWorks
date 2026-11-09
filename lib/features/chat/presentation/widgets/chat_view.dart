import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
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
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
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
  final _drafts = getIt<ChatDraftStore>();
  late final _bloc = ChatBloc(
    getIt<AgentHub>(),
    getIt<LiveOutputBus>(),
    _drafts,
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
    child: ChatBody(leading: widget.leading, drafts: _drafts),
  );
}

/// Тело чата без создания блока: блок должен быть выше по дереву (см. [ChatView]).
class ChatBody extends StatefulWidget {
  const ChatBody({this.leading, this.drafts, super.key});

  /// См. [ChatView.leading].
  final Widget? leading;

  /// Куда писать неотправленную правку. Null в виджет-тестах: правка живёт только в этом виджете.
  final ChatDraftStore? drafts;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  final _composer = TextEditingController();

  /// Поле правки уже отправленного сообщения. Не связано с черновиком нижнего композера.
  final _editController = TextEditingController();

  /// Композер переезжает между центром пустого чата и низом ленты. Ключ сохраняет его состояние при переезде.
  final _composerKey = GlobalKey();
  var _dragging = false;
  var _draftId = 0;

  /// Сообщение, пузырь которого сейчас заменён композером. Одно за раз.
  String? _editingId;
  String? _editingChatId;

  /// Снимок сообщения на момент открытия правки. С ним сравниваем текст, в том числе
  /// при закрытии виджета, когда состояние блока уже нельзя читать.
  ChatMessage? _editingSource;
  List<AttachmentRef> _editAttachments = const [];

  /// Правки, когда [ChatBody.drafts] не передан (виджет-тесты). В приложении их держит хранилище.
  final _memoryEdits = <String, Map<String, ChatDraft>>{};

  /// Правка уже отправлена и ждёт ответ по откату файлов. Пока диалог открыт, поле не сворачивается
  /// из-за начала хода: иначе отмена отката потеряла бы место, куда вернуться.
  var _editPending = false;

  @override
  void initState() {
    super.initState();
    // Поле сразу показывает черновик текущего чата. Слушатель подключаем после, чтобы не отправить его обратно.
    _composer.text = context.read<ChatBloc>().state.draft;
    _composer.addListener(_onTextChanged);
    _editController.addListener(_onEditText);
  }

  @override
  void dispose() {
    // Сначала запоминаем правку, потом блок при закрытии сразу пишет её в БД.
    _rememberEdit();
    _composer.removeListener(_onTextChanged);
    _editController.removeListener(_onEditText);
    _composer.dispose();
    _editController.dispose();
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
      listenWhen: (previous, current) =>
          previous.draftId != current.draftId ||
          previous.chatId != current.chatId ||
          previous.isRunning != current.isRunning ||
          previous.messages != current.messages,
      listener: _onBlocState,
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
                // Пока открыта правка, брошенные файлы идут в неё, а не в черновик следующего сообщения.
                dragging: _dragging && _editingId == null,
                workspace: chat.workspace,
                policy: chat.policyMode,
                onPickWorkspace: () => _pickWorkspace(bloc, chat),
                onPolicySelected: (mode) => bloc.add(ChatPolicyChanged(mode)),
                settings: _ChatSettings(
                  state: state,
                  onPickWorkspace: () => _pickWorkspace(bloc, chat),
                  onPickModel: () => _pickModel(bloc, state, chat),
                  onOpenContext: () => _openContext(bloc),
                ),
                onAttach: _pickFiles,
                onRemoveAttachment: (index) =>
                    bloc.add(ChatAttachmentRemoved(index)),
                onSubmit: (sendNow) => _submit(bloc, sendNow: sendNow),
                onStop: () => bloc.add(const ChatStopped()),
                onInputFocus: _onComposerFocus,
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
                                editingMessageId: _editingId,
                                editDraftTexts: _editDraftTexts(state.chatId),
                                messageEditor: _editingId == null
                                    ? null
                                    : _MessageEditComposer(
                                        state: state,
                                        controller: _editController,
                                        attachments: _editAttachments,
                                        dragging:
                                            _dragging && _editingId != null,
                                        submitting: _editPending,
                                        onAttach: _pickEditFiles,
                                        onRemoveAttachment:
                                            _removeEditAttachment,
                                        onSubmit: () => _submitEdit(bloc),
                                        onPark: _onParkRequested,
                                        onPickWorkspace: () =>
                                            _pickWorkspace(bloc, chat),
                                        onPolicySelected: (mode) =>
                                            bloc.add(ChatPolicyChanged(mode)),
                                        onPickModel: () =>
                                            _pickModel(bloc, state, chat),
                                        onOpenContext: () => _openContext(bloc),
                                      ),
                                onEditMessage: _startEdit,
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

  /// Черновик и правка реагируют на состояние блока. [context] нужен, чтобы не трогать поле,
  /// если слушатель уже отсоединён.
  void _onBlocState(BuildContext context, ChatState state) {
    if (!context.mounted) return;
    _applyDraft(state);
    _syncEdit(state);
    _dropOrphanEdits(state);
  }

  void _applyDraft(ChatState state) {
    if (state.draftId == _draftId) return;
    _draftId = state.draftId;
    _composer.text = state.draft;
    _composer.selection = TextSelection.collapsed(offset: state.draft.length);
  }

  /// Сворачивает правку, когда сменился чат, сообщение исчезло или начался другой ход.
  /// Свой ход правку не прячет, пока диалог отката открыт. Исчезнувшее сообщение
  /// забывает черновик: история уже переписана или сообщения больше нет.
  void _syncEdit(ChatState state) {
    if (_editingId == null) return;
    if (state.chatId != _editingChatId) {
      _parkEdit();
      return;
    }
    if (state.loading) return;
    final gone = !state.messages.any((message) => message.id == _editingId);
    if (gone) {
      _discardEdit();
      return;
    }
    if (state.isRunning && !_editPending) _parkEdit();
  }

  /// Фокус в нижнем поле: пользователь вернулся к новому сообщению, правка сворачивается.
  void _onComposerFocus(bool focused) {
    if (focused && _editingId != null && !_editPending) _parkEdit();
  }

  /// Escape и другие жесты сворачивания. Пока открыт откат файлов, поле остаётся.
  void _onParkRequested() {
    if (_editPending) return;
    _parkEdit();
  }

  void _onEditText() => _rememberEdit();

  void _startEdit(ChatMessage message) {
    if (_editPending || message.role != MessageRole.user) return;
    if (_editingId == message.id) return;
    if (_editingId != null) _parkEdit(notify: false);
    final chatId = context.read<ChatBloc>().state.chatId;
    if (chatId == null) return;
    final saved = _editOf(chatId, message.id);
    final text = saved?.text ?? message.text;
    final attachments = saved == null
        ? [...message.attachments]
        : [...saved.attachments];
    // Подстановка текста не должна записаться как новая правка поверх уже сохранённой.
    _editController.removeListener(_onEditText);
    _editController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _editController.addListener(_onEditText);
    setState(() {
      _editingId = message.id;
      _editingChatId = chatId;
      _editingSource = message;
      _editAttachments = attachments;
    });
  }

  /// Прячет композер правки и оставляет текст. Пузырь показывает этот текст и остаётся окрашенным.
  /// [notify] выключен, когда следом сразу открывается другая правка: промежуточный кадр не нужен.
  void _parkEdit({bool notify = true}) {
    if (_editingId == null) return;
    _rememberEdit();
    if (notify && mounted) {
      setState(() {
        _editingId = null;
        _editingChatId = null;
        _editingSource = null;
      });
      return;
    }
    _editingId = null;
    _editingChatId = null;
    _editingSource = null;
  }

  /// Сообщение исчезло: черновик больше не к чему приложить.
  void _discardEdit() {
    final chatId = _editingChatId;
    final id = _editingId;
    if (chatId != null && id != null) _forgetEdit(chatId, id);
    if (!mounted) {
      _editingId = null;
      _editingChatId = null;
      _editingSource = null;
      _editPending = false;
      return;
    }
    setState(() {
      _editingId = null;
      _editingChatId = null;
      _editingSource = null;
      _editPending = false;
    });
  }

  /// Пишет поле в черновик правки. Совпадение с исходным сообщением черновик убирает:
  /// помечать пузырь нечем. Пустой текст остаётся — пользователь мог стереть сообщение и уйти.
  void _rememberEdit() {
    final id = _editingId;
    final chatId = _editingChatId;
    final source = _editingSource;
    if (id == null || chatId == null || source == null) return;
    final draft = ChatDraft(
      text: _editController.text,
      attachments: _editAttachments,
    );
    if (_sameEdit(source, draft)) {
      _forgetEdit(chatId, id);
      return;
    }
    _putEdit(chatId, id, draft);
  }

  /// Правки сообщений, которых в ленте уже нет, не показываются и не должны оставаться в базе.
  void _dropOrphanEdits(ChatState state) {
    final chatId = state.chatId;
    if (chatId == null || state.loading) return;
    if (_editingChatId != null && _editingChatId != chatId) return;
    final live = <String>{for (final message in state.messages) message.id};
    final keep = _editingId;
    for (final id in _edits(chatId).keys.toList()) {
      if (id == keep || live.contains(id)) continue;
      _forgetEdit(chatId, id);
    }
  }

  void _removeEditAttachment(int index) {
    if (index < 0 || index >= _editAttachments.length) return;
    setState(() {
      _editAttachments = [..._editAttachments]..removeAt(index);
    });
    _rememberEdit();
  }

  void _submitEdit(ChatBloc bloc) {
    if (_editPending) return;
    final id = _editingId;
    if (id == null || bloc.state.loading) return;
    final text = _editController.text;
    final attachments = [..._editAttachments];
    if (text.trim().isEmpty && attachments.isEmpty) return;
    if (!_attachmentsReady(bloc, attachments)) return;
    final chatId = _editingChatId;
    setState(() => _editPending = true);
    bloc.add(
      ChatMessageEdited(
        id,
        text,
        attachments: attachments,
        onDone: (accepted) =>
            _finishEdit(accepted: accepted, chatId: chatId, messageId: id),
      ),
    );
  }

  /// Успешная отправка забывает черновик, даже если чат уже сменили и поле свернули.
  /// Отказ от отката файлов оставляет и поле, и текст.
  void _finishEdit({
    required bool accepted,
    required String? chatId,
    required String messageId,
  }) {
    if (accepted && chatId != null) _forgetEdit(chatId, messageId);
    if (!mounted) return;
    if (!accepted) {
      setState(() => _editPending = false);
      return;
    }
    setState(() {
      if (_editingId == messageId) {
        _editingId = null;
        _editingChatId = null;
        _editingSource = null;
      }
      _editPending = false;
    });
  }

  /// Текст неотправленных правок. Пустая строка остаётся в карте: пузырь показывает её, а не исходный текст.
  Map<String, String> _editDraftTexts(String? chatId) {
    if (chatId == null) return const {};
    final edits = _edits(chatId);
    if (edits.isEmpty) return const {};
    return {for (final entry in edits.entries) entry.key: entry.value.text};
  }

  Map<String, ChatDraft> _edits(String chatId) =>
      widget.drafts?.editsOf(chatId) ?? _memoryEdits[chatId] ?? const {};

  ChatDraft? _editOf(String chatId, String messageId) =>
      _edits(chatId)[messageId];

  void _putEdit(String chatId, String messageId, ChatDraft draft) {
    final store = widget.drafts;
    if (store != null) {
      store.updateEdit(chatId, messageId, draft);
      return;
    }
    final next = Map<String, ChatDraft>.of(_memoryEdits[chatId] ?? const {});
    next[messageId] = draft;
    _memoryEdits[chatId] = next;
  }

  void _forgetEdit(String chatId, String messageId) {
    final store = widget.drafts;
    if (store != null) {
      store.removeEdit(chatId, messageId);
      return;
    }
    final current = _memoryEdits[chatId];
    if (current == null || !current.containsKey(messageId)) return;
    _memoryEdits[chatId] = Map<String, ChatDraft>.of(current)
      ..remove(messageId);
  }

  void _onDragDone(DropDoneDetails details) {
    final intoEdit = _editingId != null;
    setState(() => _dragging = false);
    unawaited(
      _addFiles([for (final f in details.files) f.path], intoEdit: intoEdit),
    );
  }

  Future<void> _pickFiles() => _pickInto(intoEdit: false);

  Future<void> _pickEditFiles() => _pickInto(intoEdit: true);

  Future<void> _pickInto({required bool intoEdit}) async {
    final files = await openFiles();
    await _addFiles([for (final f in files) f.path], intoEdit: intoEdit);
  }

  /// Читает файлы и добавляет их в черновик или в открытую правку. Текст уходит в сообщение,
  /// бинарные файлы — модели отдельной частью. Путь на диске в вложение не попадает.
  /// Отказы показываются сообщением.
  Future<void> _addFiles(List<String> paths, {required bool intoEdit}) async {
    final bloc = context.read<ChatBloc>();
    final l10n = AppLocalizations.of(context);
    final limits = bloc.state.limits;
    final cacheDir = AppPlatform.current.isMobile
        ? (await getTemporaryDirectory()).path
        : null;
    final existing = intoEdit
        ? _editAttachments.length
        : bloc.state.attachments.length;
    var room = limits.attachmentsPerMessage - existing;
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
    if (items.isNotEmpty) {
      if (intoEdit && _editingId != null) {
        setState(() => _editAttachments = [..._editAttachments, ...items]);
        _rememberEdit();
      } else {
        bloc.add(ChatAttachmentsAdded(items));
      }
    }
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
}

/// Правка совпадает с уже отправленным сообщением: отдельный черновик не нужен.
bool _sameEdit(ChatMessage message, ChatDraft draft) {
  if (draft.text != message.text) return false;
  if (draft.attachments.length != message.attachments.length) return false;
  for (var i = 0; i < draft.attachments.length; i++) {
    final left = draft.attachments[i];
    final right = message.attachments[i];
    if (left.name != right.name ||
        left.mode != right.mode ||
        left.content != right.content ||
        left.mimeType != right.mimeType ||
        left.sizeBytes != right.sizeBytes ||
        left.bytes != right.bytes) {
      return false;
    }
  }
  return true;
}

/// Название модели для чипа; null — модель не выбрана ни в чате, ни в настройках.
String? _modelLabel(String? id, ModelCatalogState catalog) =>
    id == null ? null : catalog.nameOf(id);

/// Правка сообщения не останавливает ход: кнопка стоп в этой карточке не строится.
void _noop() {
  return;
}

/// Строка настроек чата под полем. Одна и та же у нижнего композера и у правки сообщения:
/// модель, хост и папка принадлежат чату, а не одному сообщению, и меняются сразу.
class _ChatSettings extends StatelessWidget {
  const _ChatSettings({
    required this.state,
    required this.onPickWorkspace,
    required this.onPickModel,
    required this.onOpenContext,
  });

  final ChatState state;
  final VoidCallback onPickWorkspace;
  final VoidCallback onPickModel;
  final VoidCallback onOpenContext;

  @override
  Widget build(BuildContext context) {
    final chat = state.chat;
    if (chat == null) return const SizedBox.shrink();
    final bloc = context.read<ChatBloc>();
    final fraction = state.promptTokens == null
        ? null
        : state.promptTokens! / (state.contextLimit ?? _defaultContextLimit);
    return ChatMetaBar(
      hosts: state.hosts,
      hostId: chat.hostId,
      onHostSelected: (id) => bloc.add(ChatHostChanged(id)),
      workspace: chat.workspace,
      onPickWorkspace: onPickWorkspace,
      modelLabel: _modelLabel(state.effectiveModelId, state.catalog),
      modelUnavailable: state.modelUnavailable,
      // Спиннер только пока название модели неизвестно: сохранённое показываем сразу.
      modelLoading:
          state.catalog.initialLoading &&
          !state.catalog.knowsName(state.effectiveModelId),
      modelPending: state.modelPending,
      onPickModel: onPickModel,
      contextFraction: fraction,
      onOpenContext: onOpenContext,
      running: state.isRunning,
      projectName: state.project?.name,
      onOpenProject: state.project == null
          ? null
          : () => openProject(context, state.project!.id),
    );
  }
}

/// Композер на месте сообщения пользователя. Настройки те же, что внизу чата;
/// текст и вложения живут только до отправки или отмены и черновик не трогают.
class _MessageEditComposer extends StatelessWidget {
  const _MessageEditComposer({
    required this.state,
    required this.controller,
    required this.attachments,
    required this.dragging,
    required this.submitting,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onSubmit,
    required this.onPark,
    required this.onPickWorkspace,
    required this.onPolicySelected,
    required this.onPickModel,
    required this.onOpenContext,
  });

  final ChatState state;
  final TextEditingController controller;
  final List<AttachmentRef> attachments;
  final bool dragging;
  final bool submitting;
  final VoidCallback onAttach;
  final void Function(int index) onRemoveAttachment;
  final VoidCallback onSubmit;

  /// Сворачивает правку, не отправляя её. Текст остаётся черновиком.
  final VoidCallback onPark;
  final VoidCallback onPickWorkspace;
  final ValueChanged<PolicyMode> onPolicySelected;
  final VoidCallback onPickModel;
  final VoidCallback onOpenContext;

  @override
  Widget build(BuildContext context) {
    final chat = state.chat;
    if (chat == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onPark},
      child: ChatComposer(
        state: state,
        controller: controller,
        attachments: attachments,
        dragging: dragging,
        embedded: true,
        editing: true,
        submitting: submitting,
        hint: l10n.messageEditHint,
        workspace: chat.workspace,
        policy: chat.policyMode,
        settings: _ChatSettings(
          state: state,
          onPickWorkspace: onPickWorkspace,
          onPickModel: onPickModel,
          onOpenContext: onOpenContext,
        ),
        onAttach: onAttach,
        onPickWorkspace: onPickWorkspace,
        onPolicySelected: onPolicySelected,
        onRemoveAttachment: onRemoveAttachment,
        onSubmit: (_) => onSubmit(),
        // Остановка в правке не показывается: кнопка есть только у нижнего композера.
        onStop: _noop,
      ),
    );
  }
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
