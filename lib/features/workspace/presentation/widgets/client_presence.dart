import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';

/// Значок устройства по строке `X-Client-Platform`.
///
/// Платформа приходит от клиента как свободный текст, поэтому сравниваем по
/// вхождению: `linux`, `macos`, `windows` относятся к настольным экранам, а
/// телефоны и браузер выглядят иначе. Неизвестное значение остаётся общим
/// значком устройств, чтобы список не терял строку.
IconData clientSessionIcon(ClientSessionView session) {
  final platform = session.clientPlatform.toLowerCase();
  if (platform.contains('android') ||
      platform.contains('ios') ||
      platform.contains('iphone') ||
      platform.contains('ipad') ||
      platform.contains('phone')) {
    return Icons.smartphone_outlined;
  }
  if (platform.contains('web') || platform.contains('browser')) {
    return Icons.language;
  }
  if (platform.contains('macos') ||
      platform.contains('windows') ||
      platform.contains('linux')) {
    return Icons.desktop_windows_outlined;
  }
  return Icons.devices_outlined;
}

/// Короткий фрагмент id сессии.
///
/// Две вкладки одного браузера выглядят одинаково: одно приложение, версия и
/// платформа. Фрагмент id делает строки различимыми, не показывая длинный
/// идентификатор целиком.
String clientSessionShortId(ClientSessionView session, {int length = 6}) =>
    session.id.characters.take(length).toString();

/// Подпись клиента для подсказки в списке чатов: приложение с версией,
/// платформа и короткий id сессии. Id нужен, когда у соседей совпадают все
/// остальные поля — например, у нескольких вкладок одного браузера.
String clientSessionTooltipLabel(ClientSessionView session) => [
  if (session.label.isNotEmpty) session.label,
  if (session.clientPlatform.isNotEmpty) session.clientPlatform,
  '#${clientSessionShortId(session)}',
].join(' · ');

/// Открывает список подключённых экранов.
///
/// [chatTitles] переводит `activeChatId` в название чата: сервер хранит только
/// id, а показывать пользователю нужно понятное место, где открыт экран.
Future<void> showClientPresenceDialog(
  BuildContext context, {
  required List<ClientSessionView> sessions,
  Stream<List<ClientSessionView>>? changes,
  Map<String, String> chatTitles = const {},
}) => showDialog<void>(
  context: context,
  builder: (context) => ClientPresenceDialog(
    sessions: sessions,
    changes: changes,
    chatTitles: chatTitles,
  ),
);

/// Кнопка присутствия: значок устройств со счётчиком других экранов.
///
/// Счётчик показывает именно соседей: текущий экран уже известен пользователю,
/// а его включение в число делало бы «1» всегда.
class ClientPresenceIconButton extends StatelessWidget {
  const ClientPresenceIconButton({
    required this.sessions,
    this.changes,
    this.badgeCount,
    this.chatTitles = const {},
    super.key,
  });

  /// Сессии для диалога. В шапке сюда приходит полный список, чтобы текущий
  /// экран не выглядел пропавшим на фоне общего списка в панели.
  final List<ClientSessionView> sessions;

  /// Поток изменений для открытого диалога. Без него список остаётся снимком
  /// на момент открытия.
  final Stream<List<ClientSessionView>>? changes;

  /// Число на значке. null — [sessions.length]. В шапке чата значок открыт,
  /// только когда есть соседи, поэтому счётчик там показывает именно их.
  final int? badgeCount;

  /// Названия чатов по id для строк списка.
  final Map<String, String> chatTitles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: l10n.chatPresenceOpen,
      icon: Badge.count(
        count: badgeCount ?? sessions.length,
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        child: const Icon(Icons.devices_outlined),
      ),
      onPressed: sessions.isEmpty
          ? null
          : () => showClientPresenceDialog(
              context,
              sessions: sessions,
              changes: changes,
              chatTitles: chatTitles,
            ),
    );
  }
}

/// Диалог списка подключённых экранов.
///
/// Показывает переданные сессии: в общем списке и в шапке чата это все
/// подключённые экраны. Пользователь видит, откуда открыт рабочий стол, какой
/// чат там выбран и находится ли окно в фокусе. Открытый диалог слушает
/// [changes] и обновляется без закрытия.
class ClientPresenceDialog extends StatefulWidget {
  const ClientPresenceDialog({
    required this.sessions,
    this.changes,
    this.chatTitles = const {},
    super.key,
  });

  final List<ClientSessionView> sessions;
  final Stream<List<ClientSessionView>>? changes;
  final Map<String, String> chatTitles;

  @override
  State<ClientPresenceDialog> createState() => _ClientPresenceDialogState();
}

class _ClientPresenceDialogState extends State<ClientPresenceDialog> {
  late List<ClientSessionView> _sessions = widget.sessions;
  StreamSubscription<List<ClientSessionView>>? _changesSub;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant ClientPresenceDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      unawaited(_changesSub?.cancel());
      _changesSub = null;
      _listen();
    }
    if (widget.changes == null && oldWidget.sessions != widget.sessions) {
      _sessions = widget.sessions;
    }
  }

  @override
  void dispose() {
    unawaited(_changesSub?.cancel());
    super.dispose();
  }

  /// Подписывается на изменения присутствия: открытый диалог обновляется сам.
  void _listen() {
    final changes = widget.changes;
    if (changes == null) return;
    _changesSub = changes.listen((sessions) {
      if (mounted) setState(() => _sessions = sessions);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ordered = [..._sessions]..sort(_compareSessions);
    return AlertDialog(
      title: Text(
        l10n.chatPresenceTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.chatPresenceBody,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (final session in ordered)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: _SessionRow(
                    session: session,
                    chatTitle: widget.chatTitles[session.activeChatId],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.chatPresenceClose),
        ),
      ],
    );
  }

  /// Текущий экран сверху, затем активные окна, затем остальные: так строка,
  /// которую пользователь ищет чаще всего, не уезжает вниз.
  static int _compareSessions(ClientSessionView a, ClientSessionView b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    if (a.focused != b.focused) return a.focused ? -1 : 1;
    return a.label.compareTo(b.label);
  }
}

/// Строка клиента: значок платформы, подпись и состояние.
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, this.chatTitle});

  final ClientSessionView session;
  final String? chatTitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeChatId = session.activeChatId;
    // Название может быть неизвестно: сосед открыл чат вне текущей вкладки.
    // Тогда показываем id, но не врём «чат не открыт».
    final activeChat = activeChatId == null
        ? null
        : (chatTitle ?? activeChatId);
    final status = [
      if (session.clientPlatform.isNotEmpty) session.clientPlatform,
      session.focused ? l10n.chatPresenceFocused : l10n.chatPresenceBackground,
      activeChat == null
          ? l10n.chatPresenceNoChat
          : l10n.chatPresenceViewing(activeChat),
      if (session.current) l10n.chatPresenceCurrent,
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            clientSessionIcon(session),
            size: 20,
            color: session.focused ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      session.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: session.current
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  MetaChip(
                    label: '#${clientSessionShortId(session)}',
                    mono: true,
                    tooltip: l10n.chatPresenceSessionId(session.id),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
