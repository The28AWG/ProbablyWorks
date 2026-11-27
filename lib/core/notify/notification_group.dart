/// Одно уведомление, показанное в группе.
///
/// [noticeId] — устойчивый ключ, по которому уведомление обновляется и
/// отменяется. [groupKey] отделяет группы друг от друга: платформа объединяет
/// уведомления с одним ключом, а сводка группы считается по этому же ключу.
final class GroupedNotice {
  const GroupedNotice({
    required this.noticeId,
    required this.groupKey,
    required this.title,
    required this.body,
    this.chatTitle = '',
    this.chatId,
    this.profileId,
  });

  final String noticeId;
  final String groupKey;
  final String title;
  final String body;

  /// Название чата для заголовка сводки. Пустое допустимо: тогда в сводке
  /// только счётчик.
  final String chatTitle;
  final String? chatId;
  final String? profileId;
}

/// Состав одной группы в момент построения сводки.
///
/// [notices] идут в порядке появления: сводка не переставляет карточки при
/// каждом обновлении одной из них. [chatId] и [profileId] берутся у первой
/// карточки — они одинаковы для всей группы, потому что входят в её ключ.
final class NoticeGroupSummary {
  const NoticeGroupSummary({
    required this.groupKey,
    required this.notices,
    this.chatTitle = '',
    this.chatId,
    this.profileId,
  });

  final String groupKey;
  final List<GroupedNotice> notices;
  final String chatTitle;
  final String? chatId;
  final String? profileId;

  /// Сколько карточек сейчас в группе. Сводку показывают только с двух.
  int get count => notices.length;
}

/// Учёт показанных уведомлений по группам.
///
/// Сам по себе `groupKey` платформа запоминает и после перезапуска, поэтому
/// карточки продолжают группироваться. Состав группы нужен для сводки
/// «3 подтверждения в чате X»: трекер собирает его из событий текущей сессии,
/// а плагин восстанавливает по оставшимся в трее уведомлениям.
///
/// Класс намеренно не знает о плагине уведомлений: так правила группы
/// проверяются обычными тестами, без платформенных каналов.
final class NoticeGroupTracker {
  final _byId = <String, GroupedNotice>{};

  /// Добавляет или обновляет карточку.
  ///
  /// Повторный показ с тем же [GroupedNotice.noticeId] не создаёт дубль и не
  /// меняет позицию карточки в группе.
  GroupedNotice show(GroupedNotice notice) {
    _byId[notice.noticeId] = notice;
    return notice;
  }

  /// Убирает карточку и возвращает её описание, если она была известна.
  ///
  /// `null` означает, что уведомление показано не в этой сессии или уже
  /// отменено: отмена несуществующей карточки ничего не делает.
  GroupedNotice? remove(String noticeId) => _byId.remove(noticeId);

  /// Сводка группы или `null`, если карточек в ней не осталось.
  NoticeGroupSummary? summary(String groupKey) {
    final notices = [
      for (final notice in _byId.values)
        if (notice.groupKey == groupKey) notice,
    ];
    if (notices.isEmpty) return null;
    return NoticeGroupSummary(
      groupKey: groupKey,
      notices: List.unmodifiable(notices),
      chatTitle: notices.first.chatTitle,
      chatId: notices.first.chatId,
      profileId: notices.first.profileId,
    );
  }

  /// Забывает все карточки группы.
  ///
  /// Нужен, когда пользователь смахнул сводку: платформа убирает вместе с ней
  /// и карточки, поэтому хранить их дальше нельзя.
  void clearGroup(String groupKey) {
    _byId.removeWhere((_, notice) => notice.groupKey == groupKey);
  }
}
