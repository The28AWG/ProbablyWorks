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

/// Короткий фрагмент fingerprint сессии.
///
/// Две вкладки одного браузера выглядят одинаково: одно приложение, версия и
/// платформа. Фрагмент fingerprint делает строки различимыми, не показывая
/// служебный идентификатор целиком.
String clientSessionShortId(ClientSessionView session, {int length = 6}) =>
    session.id.characters.take(length).toString();

/// Подпись клиента для подсказки в списке чатов: приложение с версией,
/// платформа и короткий fingerprint сессии. Fingerprint нужен, когда у соседей
/// совпадают все остальные поля — например, у нескольких вкладок браузера.
String clientSessionTooltipLabel(ClientSessionView session) => [
  if (session.label.isNotEmpty) session.label,
  if (session.clientPlatform.isNotEmpty) session.clientPlatform,
  '#${clientSessionShortId(session)}',
].join(' · ');

/// Название устройства в списке: приложение, версия и платформа.
///
/// Платформа входит в название, потому что один и тот же клиент на телефоне
/// и на настольной машине — разные устройства, даже когда версия совпадает.
String clientSessionDeviceLabel(ClientSessionView session) => [
  if (session.clientApp.isNotEmpty) session.clientApp,
  if (session.clientVersion.isNotEmpty) session.clientVersion,
  if (session.clientPlatform.isNotEmpty) session.clientPlatform,
].join(' · ');

/// Одно устройство в списке: все его вкладки и окна.
///
/// Границей группировки служит [ClientSessionView.deviceKey]: стабильный
/// `clientId`, а для старых клиентов — отпечаток `deviceId`. Две вкладки
/// одного браузера попадают в одну группу, а две машины с одинаковой версией
/// при наличии `clientId` остаются разными устройствами.
final class ClientSessionDeviceGroup {
  const ClientSessionDeviceGroup({required this.key, required this.sessions});

  /// Ключ устройства: `clientId` или запасной `deviceId`.
  final String key;

  /// Сессии устройства, уже упорядоченные для показа.
  final List<ClientSessionView> sessions;

  /// Первая сессия группы: её подпись представляет устройство.
  ClientSessionView get primary => sessions.first;

  /// Есть ли в группе текущий экран.
  bool get hasCurrent => sessions.any((session) => session.current);

  /// Есть ли в группе экран в фокусе.
  bool get hasFocused => sessions.any((session) => session.focused);
}

/// Группирует сессии по устройству и упорядочивает их для диалога.
///
/// Текущее устройство поднимается наверх, затем устройства с экраном в фокусе.
/// Внутри группы текущий экран идёт первым. Так пользователь видит знакомое
/// место раньше остальных, а не список одинаковых строк.
List<ClientSessionDeviceGroup> groupClientSessions(
  List<ClientSessionView> sessions,
) {
  final byDevice = <String, List<ClientSessionView>>{};
  for (final session in sessions) {
    byDevice.putIfAbsent(session.deviceKey, () => []).add(session);
  }
  final groups = [
    for (final entry in byDevice.entries)
      ClientSessionDeviceGroup(
        key: entry.key,
        sessions: [...entry.value]..sort(_compareSessions),
      ),
  ];
  return groups..sort(_compareGroups);
}

/// Убирает другое подключение по fingerprint из списка экранов.
///
/// Возвращает `true`, если сервер принял запрос. Ложный результат показывает
/// ошибку в диалоге, но не закрывает список: пользователь может повторить.
typedef ClientSessionCloser = Future<bool> Function(String sessionId);

/// Открывает список подключённых экранов.
///
/// [chatTitles] переводит `activeChatId` в название чата: сервер хранит только
/// id, а показывать пользователю нужно понятное место, где открыт экран.
Future<void> showClientPresenceDialog(
  BuildContext context, {
  required List<ClientSessionView> sessions,
  Stream<List<ClientSessionView>>? changes,
  Map<String, String> chatTitles = const {},
  ClientSessionCloser? onCloseSession,
}) async {
  final disconnected = await showDialog<bool>(
    context: context,
    builder: (context) => ClientPresenceDialog(
      sessions: sessions,
      changes: changes,
      chatTitles: chatTitles,
      onCloseSession: onCloseSession,
    ),
  );
  // Успех показываем после закрытия диалога: snackbar за модальным барьером
  // был бы затемнён и легко терялся.
  if (disconnected != true || !context.mounted) return;
  AppSnackBar.show(
    context,
    AppLocalizations.of(context).chatPresenceDisconnected,
  );
}

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
    this.onCloseSession,
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

  /// Действие «отключить экран». null — список только для чтения: встроенный
  /// агент соседей не имеет, а без API закрывать нечего.
  final ClientSessionCloser? onCloseSession;

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
              onCloseSession: onCloseSession,
            ),
    );
  }
}

/// Диалог списка подключённых экранов.
///
/// Показывает переданные сессии, сгруппированные по устройству: вкладки
/// одного браузера или два окна одной установки — одна группа, а разные
/// машины с одинаковой версией остаются разными, если клиент прислал
/// стабильный `clientId`. Пользователь видит, откуда открыт рабочий стол,
/// какой чат там выбран и находится ли окно в фокусе. Открытый диалог слушает
/// [changes] и обновляется без закрытия.
class ClientPresenceDialog extends StatefulWidget {
  const ClientPresenceDialog({
    required this.sessions,
    this.changes,
    this.chatTitles = const {},
    this.onCloseSession,
    super.key,
  });

  final List<ClientSessionView> sessions;
  final Stream<List<ClientSessionView>>? changes;
  final Map<String, String> chatTitles;
  final ClientSessionCloser? onCloseSession;

  @override
  State<ClientPresenceDialog> createState() => _ClientPresenceDialogState();
}

class _ClientPresenceDialogState extends State<ClientPresenceDialog> {
  late List<ClientSessionView> _sessions = widget.sessions;

  /// Раскрытые группы устройств по [ClientSessionDeviceGroup.key].
  ///
  /// Группа с текущим или активным экраном открыта сразу, остальные можно
  /// раскрыть по нажатию. Состояние переживает обновления присутствия, пока
  /// устройство остаётся в списке.
  final Map<String, bool> _expanded = {};

  /// Ошибка последней попытки отключить экран.
  ///
  /// Показывается внутри диалога, а не snackbar-ом: сообщение за модальным
  /// барьером было бы затемнено, а пользователь должен увидеть, что попытка
  /// не удалась, и повторить её.
  String? _error;

  StreamSubscription<List<ClientSessionView>>? _changesSub;

  @override
  void initState() {
    super.initState();
    _syncExpanded(_sessions);
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
      // didUpdateWidget уже вызывает сборку: setState здесь не нужен.
      _sessions = widget.sessions;
      _syncExpanded(widget.sessions);
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
      if (mounted) _setSessions(sessions);
    });
  }

  void _setSessions(List<ClientSessionView> sessions) {
    setState(() {
      _sessions = sessions;
      _syncExpanded(sessions);
    });
  }

  /// Добавляет новые устройства и убирает исчезнувшие.
  ///
  /// Уже раскрытую пользователем группу не переоткрываем: иначе каждое
  /// heartbeat с presence снова разворачивало бы список. Группу с одним
  /// экраном считаем раскрытой: её строка и так видна, и при появлении второй
  /// вкладки она не должна исчезать.
  void _syncExpanded(List<ClientSessionView> sessions) {
    final groups = groupClientSessions(sessions);
    final keys = {for (final group in groups) group.key};
    _expanded.removeWhere((key, _) => !keys.contains(key));
    for (final group in groups) {
      _expanded.putIfAbsent(
        group.key,
        () =>
            group.sessions.length == 1 || group.hasCurrent || group.hasFocused,
      );
    }
  }

  /// Раскрыта ли [group] с учётом ручного выбора пользователя.
  bool _isExpanded(ClientSessionDeviceGroup group) =>
      _expanded[group.key] ?? group.sessions.length == 1;

  /// Убирает чужое подключение после подтверждения.
  ///
  /// Закрытие чужого экрана — уборка зависшей сессии, а не отзыв доступа:
  /// открытый экран пройдёт рукопожатие заново. Поэтому диалог не обещает,
  /// что вкладка закроется. После успеха диалог закрывается, а ошибка
  /// остаётся внутри него, чтобы попытку можно было повторить.
  Future<void> _disconnect(ClientSessionView session) async {
    final closer = widget.onCloseSession;
    if (closer == null) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.chatPresenceDisconnectScreen,
      message: l10n.chatPresenceDisconnectConfirm(
        clientSessionTooltipLabel(session),
      ),
      cancelLabel: l10n.chatPresenceClose,
      confirmLabel: l10n.chatPresenceDisconnectScreen,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final disconnected = await closer(session.id);
    if (!mounted) return;
    if (disconnected) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _error = l10n.chatPresenceDisconnectFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final groups = groupClientSessions(_sessions);
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
              if (_error case final error?) ...[
                AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.danger,
                  icon: Icons.error_outline,
                  message: error,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              for (final group in groups)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: _DeviceGroup(
                    group: group,
                    expanded: _isExpanded(group),
                    onToggle: () => setState(
                      () => _expanded[group.key] = !_isExpanded(group),
                    ),
                    chatTitles: widget.chatTitles,
                    onDisconnect: widget.onCloseSession == null
                        ? null
                        : _disconnect,
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
}

/// Устройство и его вкладки.
class _DeviceGroup extends StatelessWidget {
  const _DeviceGroup({
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.chatTitles,
    required this.onDisconnect,
  });

  final ClientSessionDeviceGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final Map<String, String> chatTitles;

  /// Подтверждает и убирает чужой экран. null — список только для чтения.
  final Future<void> Function(ClientSessionView session)? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final multiple = group.sessions.length > 1;
    final name = clientSessionDeviceLabel(group.primary);
    final displayName = name.isEmpty ? l10n.chatPresenceUnknownDevice : name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: multiple ? onToggle : null,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Row(
              children: [
                Icon(
                  clientSessionIcon(group.primary),
                  size: 20,
                  color: group.hasFocused
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: group.hasCurrent
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                MetaChip(
                  label: l10n.chatPresenceDeviceScreens(group.sessions.length),
                ),
                if (multiple) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: AppDurations.fast,
          alignment: Alignment.topCenter,
          child: expanded || !multiple
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final session in group.sessions)
                      Padding(
                        // Подпись устройства начинается после InkWell (xs),
                        // значка (20) и отступа (md): 4 + 20 + 12 = 36.
                        // Строка вкладки выравнивается по этой подписи, а не
                        // по значку устройства.
                        padding: const EdgeInsetsDirectional.only(
                          start: AppSpacing.xxl + AppSpacing.xs,
                          bottom: AppSpacing.sm,
                        ),
                        child: _SessionRow(
                          session: session,
                          chatTitle: chatTitles[session.activeChatId],
                          onDisconnect: session.current
                              ? null
                              : onDisconnect == null
                              ? null
                              : () => onDisconnect!(session),
                        ),
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Строка сессии внутри устройства: fingerprint и состояние.
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, this.chatTitle, this.onDisconnect});

  final ClientSessionView session;
  final String? chatTitle;

  /// Убирает этот экран. Для текущего и для списка только для чтения — null.
  final VoidCallback? onDisconnect;

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
      // У MetaChip есть вертикальный отступ: без центрирования чип
      // оказывается ниже текста статуса. Центрируем его по блоку статуса.
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        MetaChip(
          label: '#${clientSessionShortId(session)}',
          mono: true,
          tooltip: l10n.chatPresenceSessionId(session.id),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: session.current
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (onDisconnect != null)
          IconButton(
            tooltip: l10n.chatPresenceDisconnectScreen,
            icon: const Icon(Icons.link_off, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: onDisconnect,
          ),
      ],
    );
  }
}

/// Текущий экран сверху, затем активные окна, затем остальные.
int _compareSessions(ClientSessionView a, ClientSessionView b) {
  if (a.current != b.current) return a.current ? -1 : 1;
  if (a.focused != b.focused) return a.focused ? -1 : 1;
  return a.label.compareTo(b.label);
}

/// Устройства с текущим и активным экраном поднимаются наверх.
int _compareGroups(ClientSessionDeviceGroup a, ClientSessionDeviceGroup b) {
  if (a.hasCurrent != b.hasCurrent) return a.hasCurrent ? -1 : 1;
  if (a.hasFocused != b.hasFocused) return a.hasFocused ? -1 : 1;
  final byName = a.primary.label.compareTo(b.primary.label);
  if (byName != 0) return byName;
  return a.key.compareTo(b.key);
}
