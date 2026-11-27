import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/scheduler.dart'
    show AppLifecycleState, SchedulerBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/notify/notification_action.dart';
import 'package:probably_works/core/notify/notification_group.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

/// Заголовок и текст системного уведомления.
/// Заголовок — «действие · название чата», тело — что нужно сделать пользователю.
({String title, String body}) composeAgentNotice(
  AppLocalizations l10n, {
  required AgentNoticeKind kind,
  required String chatTitle,
  String? detail,
}) {
  final action = switch (kind) {
    AgentNoticeKind.approvalNeeded => l10n.approvalTitle,
    AgentNoticeKind.questionAsked => l10n.questionTitle,
    AgentNoticeKind.turnFinished => l10n.notifyFinishedTitle,
    AgentNoticeKind.turnFailed => l10n.notifyFailedTitle,
    AgentNoticeKind.stepLimitReached => l10n.notifyStepLimitTitle,
    AgentNoticeKind.turnBudgetReached => l10n.notifyBudgetTitle,
    AgentNoticeKind.progressStalled => l10n.notifyStalledTitle,
    AgentNoticeKind.snoozeDue => l10n.notifySnoozedDueTitle,
    AgentNoticeKind.attentionDigest => l10n.notifyDigestTitle,
    AgentNoticeKind.backgroundFinished => l10n.notifyBackgroundTitle,
  };
  final body = switch (kind) {
    AgentNoticeKind.approvalNeeded => l10n.notifyApprovalBody,
    AgentNoticeKind.questionAsked => l10n.notifyQuestionBody,
    AgentNoticeKind.turnFinished => l10n.notifyFinishedBody,
    AgentNoticeKind.turnFailed => l10n.notifyFailedBody,
    AgentNoticeKind.stepLimitReached => l10n.notifyStepLimitBody,
    AgentNoticeKind.turnBudgetReached => l10n.notifyBudgetBody,
    AgentNoticeKind.progressStalled => l10n.notifyStalledBody,
    AgentNoticeKind.snoozeDue => l10n.notifySnoozedDueBody,
    AgentNoticeKind.attentionDigest => l10n.notifyDigestBody,
    AgentNoticeKind.backgroundFinished => l10n.notifyBackgroundBody(
      detail ?? '',
    ),
  };
  final name = chatTitle.trim();
  return (title: name.isEmpty ? action : '$action · $name', body: body);
}

/// Целочисленный id для платформенного API уведомлений.
///
/// Платформа принимает только int, а стабильный ключ — строка. FNV-1a даёт
/// одинаковый id при повторном показе и отмене, в том числе после перезапуска
/// приложения: уведомление с тем же ключом обновляется, а не дублируется.
/// Старший бит снят и у начального значения: некоторые платформы считают id
/// знаковым, а хеш пустой строки иначе остался бы больше 2^31-1.
int notificationPluginId(String noticeId) {
  var hash = 0x811c9dc5 & 0x7fffffff;
  for (final unit in noticeId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? 1 : hash;
}

/// Нужно ли показывать системное уведомление при данном состоянии жизненного цикла.
///
/// Во Flutter `resumed` означает, что окно в фокусе (на desktop — хотя бы одно окно приложения
/// получило фокус; на мобильных — приложение на переднем плане). Любое другое состояние
/// (`inactive`, `hidden`, `paused`, `detached`) и отсутствие состояния (`null`, до первого кадра)
/// считаем «не в фокусе»: лучше лишнее уведомление, чем пропущенный запрос подтверждения.
bool shouldShowNotification(AppLifecycleState? state) =>
    state != AppLifecycleState.resumed;

/// Уведомления через flutter_local_notifications: Android, iOS, macOS, Linux, Windows.
/// Разрешение спрашиваем при первом уведомлении (Android 13+, iOS, macOS). Отказ или ошибка
/// уведомления не ломают ход агента: событие просто не показывается.
/// Состояние фокуса проверяем в момент вызова, до инициализации плагина и запроса разрешения:
/// если приложение в фокусе, системный запрос разрешения не должен появляться зря.
/// Язык текста берётся из выбранной в настройках локали (как у фоновых уведомлений).
@LazySingleton(as: AppNotifier)
final class PluginAppNotifier implements AppNotifier, NotificationActionSink {
  /// Конструктор для DI. Плагин создаётся здесь: в GetIt его регистрировать не нужно.
  @factoryMethod
  PluginAppNotifier(LocaleController locale)
    : this.withPlugin(FlutterLocalNotificationsPlugin(), locale);

  /// Подмена плагина (тесты и нестандартная инициализация).
  PluginAppNotifier.withPlugin(this._plugin, this._locale);

  final FlutterLocalNotificationsPlugin _plugin;
  final LocaleController _locale;
  final _log = Logger('AppNotifier');

  Future<bool>? _ready;
  Future<void>? _permission;
  NotificationActionHandler? _actionHandler;
  NotificationActionRequest? _pendingAction;

  /// Состав групп текущей сессии. По нему строится сводка «3 подтверждения
  /// в чате X»; платформа группирует карточки и без него, но не отдаёт
  /// надёжный счётчик для заголовка.
  final _groups = NoticeGroupTracker();

  Future<void>? _badgePermission;

  static const _channelId = 'agent_events';
  static const _channelName = 'Agent events';
  static const _unreadChannelId = 'unread_badge';
  static const _unreadTag = 'unread-badge';
  static const _approvalCategory = 'agent_approval';
  static const _questionCategory = 'agent_question';
  static const _actionApprove = 'approve';
  static const _actionDeny = 'deny';
  static const _actionReply = 'reply';
  static const _actionOpen = 'open';

  @override
  set actionHandler(NotificationActionHandler? handler) {
    _actionHandler = handler;
    final pending = _pendingAction;
    if (handler == null || pending == null) return;
    _pendingAction = null;
    unawaited(_dispatch(pending));
  }

  /// Инициализация плагина и регистрация категорий действий. Bootstrap
  /// вызывает её после применения языка, чтобы подписи кнопок были
  /// локализованы. Повторный вызов безопасен.
  Future<void> initialize() async {
    await (_ready ??= _initialize());
  }

  /// Разрешения и каналы не просим при старте: только когда есть что показать.
  /// Если окно в фокусе, ничего не делаем: ни инициализации, ни показа.
  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
    String? questionId,
    String? noticeId,
  }) async {
    if (!shouldShowNotification(SchedulerBinding.instance.lifecycleState)) {
      return;
    }
    try {
      final strings = _strings();
      final text = composeAgentNotice(
        strings,
        kind: kind,
        chatTitle: chatTitle,
        detail: detail,
      );
      final ready = _ready ??= _initialize();
      if (!await ready) return;
      final permission = _permission ??= _requestPermissions();
      await permission;
      final approval = kind == AgentNoticeKind.approvalNeeded;
      final question = kind == AgentNoticeKind.questionAsked;
      final resolvedId =
          noticeId ??
          agentNoticeId(
            kind: kind,
            scope: profileId,
            chatId: chatId,
            approvalId: approvalId,
            questionId: questionId,
          );
      final groupKey = agentNoticeGroupKey(
        kind: kind,
        scope: profileId,
        chatId: chatId,
      );
      final payload = _encodePayload(
        profileId: profileId,
        chatId: chatId,
        approvalId: approvalId,
        questionId: questionId,
        noticeId: resolvedId,
        groupKey: groupKey,
        chatTitle: chatTitle.trim(),
      );
      await _plugin.show(
        id: notificationPluginId(resolvedId),
        title: text.title,
        body: text.body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            groupKey: groupKey,
            // Тег повторяет устойчивый ключ: `getActiveNotifications` не отдаёт
            // payload, и после перезапуска состав групп восстанавливается по
            // паре tag + groupKey.
            tag: resolvedId,
            // Каждая новая карточка должна звучать отдельно: сводка не
            // заменяет её звук и не будит пользователя второй раз.
            groupAlertBehavior: GroupAlertBehavior.children,
            // Смахивание карточки должно уменьшать сводку группы. Без этого
            // трекер считает снятую пользователем карточку всё ещё показанной.
            dismissIsolate: NotificationDismissedIsolate.main,
            actions: switch (kind) {
              AgentNoticeKind.approvalNeeded => _androidApprovalActions(
                strings,
              ),
              AgentNoticeKind.questionAsked => _androidQuestionActions(strings),
              _ => null,
            },
          ),
          iOS: DarwinNotificationDetails(
            threadIdentifier: groupKey,
            categoryIdentifier: approval
                ? _approvalCategory
                : question
                ? _questionCategory
                : null,
          ),
          macOS: DarwinNotificationDetails(
            threadIdentifier: groupKey,
            categoryIdentifier: approval
                ? _approvalCategory
                : question
                ? _questionCategory
                : null,
          ),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
      );
      if (groupKey != null) {
        _groups.show(
          GroupedNotice(
            noticeId: resolvedId,
            groupKey: groupKey,
            title: text.title,
            body: text.body,
            chatTitle: chatTitle.trim(),
            chatId: chatId,
            profileId: profileId,
          ),
        );
        await _refreshGroupSummary(groupKey);
      }
    } on Object catch (error) {
      _log.fine('notification skipped: $error');
    }
  }

  @override
  Future<void> cancel(String noticeId) async {
    try {
      // Инициализация нужна и для отмены: платформенная реализация плагина
      // регистрируется в `initialize`, а без неё `cancel` — no-op на Android
      // и исключение на остальных платформах. Разрешения при этом не
      // запрашиваются: они остаются заботой показа.
      final ready = _ready ??= _initialize();
      if (!await ready) return;
      final group = _groups.remove(noticeId);
      await _cancelById(noticeId);
      // Закрытая карточка могла быть последней в группе: сводка не должна
      // звать к уже разобранным решениям.
      if (group != null) await _refreshGroupSummary(group.groupKey);
    } on Object catch (error) {
      _log.fine('notification cancel skipped: $error');
    }
  }

  /// Обновляет бейдж приложения и трея.
  ///
  /// Android показывает число на иконке через активное уведомление: отдельного
  /// API у плагина нет. Поэтому при непрочитанном появляется тихая
  /// несбрасываемая карточка со счётчиком, а при нуле она снимается. iOS и
  /// macOS получают badge без видимой карточки: уведомление нужно только как
  /// носитель `badgeNumber`.
  ///
  /// Разрешение спрашивается лениво и один раз, при первом непрочитанном;
  /// отказ не ломает чат и не повторяется на каждом сообщении. Нулевой счётчик
  /// только снимает бейдж: системный запрос без непрочитанного не появляется.
  @override
  Future<void> setUnreadCount(int count) async {
    if (count < 0) return;
    try {
      final ready = _ready ??= _initialize();
      if (!await ready) return;
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          await _setAndroidBadge(count);
        case TargetPlatform.iOS:
          await _setDarwinBadge(count, macOS: false);
        case TargetPlatform.macOS:
          await _setDarwinBadge(count, macOS: true);
        case TargetPlatform.linux ||
            TargetPlatform.windows ||
            TargetPlatform.fuchsia:
          // На Linux и Windows стандартного бейджа иконки нет: не выдаём
          // системное уведомление только ради числа.
          return;
      }
    } on Object catch (error) {
      _log.fine('badge update skipped: $error');
    }
  }

  /// Счётчик на иконке Android через тихую карточку в трее.
  ///
  /// Карточка нужна платформе: лаунчер считает бейдж по активным
  /// уведомлениям. Она не звучит, не вибрирует и не обновляется по времени,
  /// поэтому не мешает карточкам подтверждений.
  Future<void> _setAndroidBadge(int count) async {
    final id = notificationPluginId(_unreadTag);
    if (count == 0) {
      await _plugin.cancel(id: id, tag: _unreadTag);
      return;
    }
    await (_badgePermission ??= _requestBadgePermission());
    final strings = _strings();
    await _plugin.show(
      id: id,
      title: strings.chatUnreadCount(count),
      body: strings.notifyUnreadSummaryBody,
      payload: null,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _unreadChannelId,
          strings.notifyUnreadChannelName,
          channelDescription: strings.notifyUnreadChannelDescription,
          importance: Importance.low,
          priority: Priority.low,
          channelShowBadge: true,
          playSound: false,
          enableVibration: false,
          silent: true,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
          number: count,
          tag: _unreadTag,
          styleInformation: BigTextStyleInformation(
            strings.notifyUnreadSummaryBody,
          ),
        ),
      ),
    );
  }

  /// Бейдж иконки iOS/macOS без видимой карточки.
  ///
  /// `presentList`/`presentBanner` выключены, поэтому уведомление не попадает
  /// в центр уведомлений: оно только переносит `badgeNumber`. Ноль снимает
  /// бейдж. Разрешение для нуля не запрашивается: первый счётчик при открытии
  /// оболочки всегда нулевой, и системный запрос не должен появляться без
  /// непрочитанного. Если разрешение выдано в прошлой сессии, показ нуля
  /// по-прежнему снимает оставшийся бейдж; без разрешения он просто не
  /// доставляется.
  Future<void> _setDarwinBadge(int count, {required bool macOS}) async {
    if (count > 0) {
      await (_badgePermission ??= _requestBadgePermission());
    }
    await _plugin.show(
      id: notificationPluginId(_unreadTag),
      title: null,
      body: null,
      payload: null,
      notificationDetails: NotificationDetails(
        iOS: macOS
            ? null
            : DarwinNotificationDetails(
                badgeNumber: count,
                presentAlert: false,
                presentBadge: true,
                presentSound: false,
                presentBanner: false,
                presentList: false,
                threadIdentifier: _unreadTag,
              ),
        macOS: macOS
            ? DarwinNotificationDetails(
                badgeNumber: count,
                presentAlert: false,
                presentBadge: true,
                presentSound: false,
                presentBanner: false,
                presentList: false,
                threadIdentifier: _unreadTag,
              )
            : null,
      ),
    );
  }

  /// Разрешение только на бейдж: обычные уведомления остаются на своём пороге.
  Future<void> _requestBadgePermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: false, badge: true, sound: false);
    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: false, badge: true, sound: false);
  }

  /// Убирает уведомление по устойчивому ключу.
  ///
  /// Новые уведомления показываются с `tag`, совпадающим с ключом, поэтому
  /// отмена без тега их не находит. Бестеговый вызов оставлен для уведомлений,
  /// показанных прошлыми версиями.
  Future<void> _cancelById(String noticeId) async {
    final id = notificationPluginId(noticeId);
    await _plugin.cancel(id: id, tag: noticeId);
    // Старые версии показывали уведомления без tag; на Android это отдельная
    // запись, поэтому снимаем и её.
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin.cancel(id: id);
    }
  }

  /// Обновляет сводку группы по её текущему составу.
  ///
  /// Сводка нужна только на Android: iOS и macOS сами объединяют карточки по
  /// `threadIdentifier`, и вторая строка «3 события» была бы лишней. С одной
  /// карточкой сводка тоже не показывается: она повторяла бы саму карточку.
  Future<void> _refreshGroupSummary(String groupKey) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final summary = _groups.summary(groupKey);
    final summaryId = _summaryNoticeId(groupKey);
    final id = notificationPluginId(summaryId);
    if (summary == null || summary.count < 2) {
      await _cancelById(summaryId);
      return;
    }
    final strings = _strings();
    final count = summary.count;
    final title = strings.notifyGroupSummaryTitle(count);
    final chat = summary.chatTitle;
    await _plugin.show(
      id: id,
      title: chat.isEmpty ? title : '$title · $chat',
      body: strings.notifyGroupSummaryBody,
      payload: _encodePayload(
        profileId: summary.profileId,
        chatId: summary.chatId,
        noticeId: summaryId,
        groupKey: groupKey,
        chatTitle: summary.chatTitle,
      ),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          groupKey: groupKey,
          setAsGroupSummary: true,
          tag: summaryId,
          dismissIsolate: NotificationDismissedIsolate.main,
          groupAlertBehavior: GroupAlertBehavior.children,
          onlyAlertOnce: true,
          styleInformation: InboxStyleInformation(
            [for (final notice in summary.notices.take(5)) notice.title],
            contentTitle: chat.isEmpty ? title : '$title · $chat',
            summaryText: strings.notifyGroupSummaryBody,
          ),
          actions: [
            AndroidNotificationAction(
              _actionOpen,
              strings.notifyActionReview,
              showsUserInterface: true,
            ),
          ],
        ),
      ),
    );
  }

  /// Суффикс id сводки группы. По нему обработчик смахивания отличает сводку
  /// от карточки: у сводки нет своего элемента в трекере.
  static const _summarySuffix = '#summary';

  /// Сводка группы живёт отдельным id: обновление карточки не должно
  /// перезаписывать заголовок группы, а отмена карточки — попадать в неё.
  static String _summaryNoticeId(String groupKey) => '$groupKey$_summarySuffix';

  List<AndroidNotificationAction> _androidApprovalActions(
    AppLocalizations l10n,
  ) => [
    AndroidNotificationAction(
      _actionApprove,
      l10n.notifyActionApprove,
      showsUserInterface: true,
    ),
    AndroidNotificationAction(
      _actionDeny,
      l10n.notifyActionDeny,
      showsUserInterface: true,
    ),
    AndroidNotificationAction(
      _actionOpen,
      l10n.notifyActionOpen,
      showsUserInterface: true,
    ),
  ];

  /// Ответ на вопрос прямо из уведомления: RemoteInput открывает поле ввода.
  ///
  /// Действие обязано показывать интерфейс: без этого платформа отдаёт ответ
  /// фоновому изоляту, а у приложения нет фоновой точки входа для ответа на
  /// вопрос. Поэтому после «Отправить» открывается приложение, а текст уходит
  /// в обычный обработчик действий. Идемпотентность ответа обеспечивает
  /// `agentNoticeAnswerId`.
  List<AndroidNotificationAction> _androidQuestionActions(
    AppLocalizations l10n,
  ) => [
    AndroidNotificationAction(
      _actionReply,
      l10n.notifyActionReply,
      inputs: [
        AndroidNotificationActionInput(label: l10n.notifyReplyPlaceholder),
      ],
      allowGeneratedReplies: true,
      showsUserInterface: true,
    ),
    AndroidNotificationAction(
      _actionOpen,
      l10n.notifyActionOpen,
      showsUserInterface: true,
    ),
  ];

  /// Категории iOS/macOS с теми же действиями. Кнопка «Открыть» не нужна:
  /// нажатие на само уведомление уже открывает чат, поэтому в категории
  /// остаются только решения.
  ///
  /// Текстовое действие помечено `foreground`: иначе ответ ушёл бы фоновому
  /// изоляту, а у приложения нет фоновой точки входа для вопроса. Плата —
  /// открытие приложения после отправки ответа.
  List<DarwinNotificationCategory> _darwinCategories(AppLocalizations l10n) => [
    DarwinNotificationCategory(
      _approvalCategory,
      actions: [
        DarwinNotificationAction.plain(
          _actionApprove,
          l10n.notifyActionApprove,
          options: const {DarwinNotificationActionOption.foreground},
        ),
        DarwinNotificationAction.plain(
          _actionDeny,
          l10n.notifyActionDeny,
          options: const {DarwinNotificationActionOption.foreground},
        ),
      ],
    ),
    DarwinNotificationCategory(
      _questionCategory,
      actions: [
        DarwinNotificationAction.text(
          _actionReply,
          l10n.notifyActionReply,
          buttonTitle: l10n.notifyActionSendReply,
          placeholder: l10n.notifyReplyPlaceholder,
          options: const {DarwinNotificationActionOption.foreground},
        ),
      ],
    ),
  ];

  static String? _encodePayload({
    String? profileId,
    String? chatId,
    String? approvalId,
    String? questionId,
    String? noticeId,
    String? groupKey,
    String? chatTitle,
  }) {
    if (profileId == null &&
        chatId == null &&
        approvalId == null &&
        questionId == null &&
        noticeId == null &&
        groupKey == null &&
        (chatTitle == null || chatTitle.isEmpty)) {
      return null;
    }
    final data = <String, String>{};
    if (profileId != null) data['profileId'] = profileId;
    if (chatId != null) data['chatId'] = chatId;
    if (approvalId != null) data['approvalId'] = approvalId;
    if (questionId != null) {
      data['questionId'] = questionId;
      data['answerId'] = agentNoticeAnswerId(questionId);
    }
    // Ключ и группа нужны обработчику смахивания: по ним карточку находят без
    // её текста. На Android `getActiveNotifications` не отдаёт payload, поэтому
    // для восстановления после перезапуска те же значения дублируются в tag.
    if (noticeId != null) data['noticeId'] = noticeId;
    if (groupKey != null) data['groupKey'] = groupKey;
    if (chatTitle != null && chatTitle.isNotEmpty) {
      data['chatTitle'] = chatTitle;
    }
    return jsonEncode(data);
  }

  static Map<String, Object?> _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return const {};
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.key is String) entry.key as String: entry.value,
        };
      }
    } on FormatException {
      // Битый payload не должен мешать обработке нажатия.
    }
    return const {};
  }

  Future<void> _onResponse(NotificationResponse response) async {
    final data = _decodePayload(response.payload);
    // Смахивание карточки не является действием: его нужно только снять с
    // учёта, иначе сводка группы останется с прежним счётчиком.
    if (response.notificationResponseType ==
        NotificationResponseType.notificationDismissed) {
      await _handleDismissed(data);
      return;
    }
    final rawAction = switch (response.actionId) {
      _actionApprove => NotificationActionKind.approve,
      _actionDeny => NotificationActionKind.deny,
      _actionReply => NotificationActionKind.answer,
      _ => NotificationActionKind.open,
    };
    final approvalId = data['approvalId'] as String?;
    final questionId = data['questionId'] as String?;
    final answerText = response.input?.trim();
    // Без id карточки действие невозможно: остаётся открыть чат. Пустой
    // ответ не отправляем: пользователь мог закрыть поле ввода.
    final action = switch (rawAction) {
      NotificationActionKind.approve || NotificationActionKind.deny =>
        approvalId == null ? NotificationActionKind.open : rawAction,
      NotificationActionKind.answer =>
        questionId == null || answerText == null || answerText.isEmpty
            ? NotificationActionKind.open
            : rawAction,
      NotificationActionKind.open => NotificationActionKind.open,
    };
    await _dispatch(
      NotificationActionRequest(
        action: action,
        profileId: data['profileId'] as String?,
        chatId: data['chatId'] as String?,
        approvalId: approvalId,
        questionId: questionId,
        answerText: answerText,
        answerId: data['answerId'] as String?,
      ),
    );
  }

  /// Снимает с учёта карточку, которую пользователь убрал из трея.
  ///
  /// Для сводки забывается вся группа: платформа смахивает её вместе с
  /// карточками, а собственная запись сводки в трекере не хранится.
  Future<void> _handleDismissed(Map<String, Object?> data) async {
    final noticeId = data['noticeId'] as String?;
    if (noticeId == null) return;
    if (noticeId.endsWith(_summarySuffix)) {
      final groupKey = data['groupKey'] as String?;
      if (groupKey != null) _groups.clearGroup(groupKey);
      return;
    }
    final group = _groups.remove(noticeId);
    if (group != null) await _refreshGroupSummary(group.groupKey);
  }

  Future<void> _dispatch(NotificationActionRequest request) async {
    final handler = _actionHandler;
    if (handler == null) {
      _pendingAction = request;
      return;
    }
    try {
      await handler(request);
    } on Object catch (error) {
      _log.warning('notification action failed: $error');
    }
  }

  AppLocalizations _strings() =>
      lookupAppLocalizations(resolveAppLocale(_locale.value?.languageCode));

  Future<bool> _initialize() async {
    final l10n = _strings();
    final ok = await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: _darwinCategories(l10n),
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: _darwinCategories(l10n),
        ),
        linux: LinuxInitializationSettings(
          defaultActionName: l10n.notifyActionOpen,
        ),
        windows: const WindowsInitializationSettings(
          appName: 'ProbablyWorks',
          appUserModelId: 'ProbablyWorks.App',
          guid: '6c0e2b6a-7f3e-4c1d-9a8b-2f5e7d1c4b90',
        ),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
    final ready = ok ?? false;
    if (ready) {
      // Сначала восстанавливаем группы по оставшимся в трее уведомлениям:
      // действие из launch details может закрыть карточку, и она должна быть
      // уже известна трекеру.
      await _restoreGroups();
      await _handleLaunchDetails();
    }
    return ready;
  }

  /// Восстанавливает состав групп по уведомлениям, оставшимся в трее.
  ///
  /// После перезапуска трекер пуст, а карточки и сводка могли остаться. У
  /// Android `getActiveNotifications` не отдаёт payload, поэтому ключ карточки
  /// берётся из `tag`, а чат — из её `groupKey`. Это возвращает сводке
  /// правильный счётчик и позволяет следующей отмене её обновить.
  Future<void> _restoreGroups() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final active =
          await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.getActiveNotifications() ??
          const <ActiveNotification>[];
      final groupKeys = <String>{};
      final chatTitles = <String, String>{};
      for (final notification in active) {
        final groupKey = notification.groupKey;
        final tag = notification.tag;
        final channel = notification.channelId;
        if (groupKey == null || tag == null) continue;
        if (channel != null && channel != _channelId) continue;
        groupKeys.add(groupKey);
        if (!tag.endsWith(_summarySuffix)) continue;
        // Заголовок сводки — «N событий · Чат». Отдельного поля с названием
        // чата в активном уведомлении нет, поэтому берём хвост заголовка.
        final parts = (notification.title ?? '').split(' · ');
        if (parts.length > 1) {
          chatTitles[groupKey] = parts.sublist(1).join(' · ').trim();
        }
      }
      for (final notification in active) {
        final groupKey = notification.groupKey;
        final tag = notification.tag;
        final channel = notification.channelId;
        if (groupKey == null || tag == null) continue;
        if (channel != null && channel != _channelId) continue;
        if (tag.endsWith(_summarySuffix)) continue;
        final location = _parseGroupKey(groupKey);
        if (location == null) continue;
        _groups.show(
          GroupedNotice(
            noticeId: tag,
            groupKey: groupKey,
            title: notification.title ?? '',
            body: notification.body ?? '',
            chatTitle: chatTitles[groupKey] ?? '',
            chatId: location.chatId,
            profileId: location.profileId,
          ),
        );
      }
      for (final groupKey in groupKeys) {
        await _refreshGroupSummary(groupKey);
      }
    } on Object catch (error) {
      _log.fine('notification group restore skipped: $error');
    }
  }

  /// Разбирает ключ группы `scope:kind:chatId` обратно на профиль и чат.
  static ({String? profileId, String chatId})? _parseGroupKey(String groupKey) {
    final parts = groupKey.split(':');
    if (parts.length < 3) return null;
    final chatId = parts.sublist(2).join(':');
    if (chatId.isEmpty) return null;
    return (
      profileId: parts.first == 'local' ? null : parts.first,
      chatId: chatId,
    );
  }

  /// Приложение могли запустить нажатием на действие. Плагин отдаёт это
  /// отдельно от `onDidReceiveNotificationResponse`, поэтому проверяем явно.
  Future<void> _handleLaunchDetails() async {
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        await _onResponse(response);
      }
    } on Object catch (error) {
      _log.fine('notification launch details skipped: $error');
    }
  }

  Future<void> _requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }
}
