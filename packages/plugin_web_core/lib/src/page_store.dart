import 'dart:collection';

import 'package:plugin_web_core/src/fetch/page_document.dart';
import 'package:plugin_web_core/src/search/search_result.dart';
import 'package:uuid/uuid.dart';

/// Снимок страницы, который живёт ограниченное время.
final class PageSnapshot {
  const PageSnapshot({
    required this.id,
    required this.chatId,
    required this.requestedUrl,
    required this.finalUrl,
    required this.title,
    required this.lang,
    required this.published,
    required this.contentType,
    required this.fetchedAt,
    required this.cleanedHtml,
    required this.text,
    required this.outline,
    required this.mode,
    required this.createdAt,
    required this.lastAccess,
  });

  final String id;
  final String chatId;
  final String requestedUrl;
  final String finalUrl;
  final String title;
  final String lang;
  final String published;
  final String contentType;
  final DateTime fetchedAt;
  final String cleanedHtml;
  final String text;
  final List<PageOutlineEntry> outline;
  final String mode;
  final DateTime createdAt;
  final DateTime lastAccess;

  int get charCount => text.length;

  /// Копия с новым представлением и временем доступа.
  PageSnapshot withView({
    required String mode,
    required String text,
    required List<PageOutlineEntry> outline,
    required DateTime lastAccess,
  }) => PageSnapshot(
    id: id,
    chatId: chatId,
    requestedUrl: requestedUrl,
    finalUrl: finalUrl,
    title: title,
    lang: lang,
    published: published,
    contentType: contentType,
    fetchedAt: fetchedAt,
    cleanedHtml: cleanedHtml,
    text: text,
    outline: outline,
    mode: mode,
    createdAt: createdAt,
    lastAccess: lastAccess,
  );

  PageSnapshot touch(DateTime value) =>
      withView(mode: mode, text: text, outline: outline, lastAccess: value);
}

/// Ограниченное in-memory хранилище страниц по чатам.
///
/// Сырой HTML сюда не попадает: только нормализованный текст и очищенный DOM.
/// Вытеснение — LRU по чату и по процессу; TTL не даёт кэшу жить вечно.
final class WebPageStore {
  WebPageStore({
    DateTime Function()? now,
    this.maxPagesPerChat = 8,
    this.maxPagesTotal = 32,
    this.maxCharsTotal = 2000000,
    this.maxHtmlTotal = 16000000,
    this.ttl = const Duration(minutes: 30),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final int maxPagesPerChat;
  final int maxPagesTotal;
  final int maxCharsTotal;
  final int maxHtmlTotal;
  final Duration ttl;

  final _chats = <String, LinkedHashMap<String, PageSnapshot>>{};

  static const _uuid = Uuid();

  /// Создаёт новый снимок и кладёт его в хранилище.
  PageSnapshot put({
    required String chatId,
    required PageDocument document,
    required String mode,
  }) {
    final now = _now();
    final snapshot = PageSnapshot(
      id: 'p_${_uuid.v4()}',
      chatId: chatId,
      requestedUrl: document.requestedUrl,
      finalUrl: document.finalUrl,
      title: document.title,
      lang: document.lang,
      published: document.published,
      contentType: document.contentType,
      fetchedAt: document.fetchedAt ?? now,
      cleanedHtml: document.cleanedHtml,
      text: document.text,
      outline: document.outline,
      mode: mode,
      createdAt: now,
      lastAccess: now,
    );
    _chats.putIfAbsent(chatId, LinkedHashMap.new)
      ..remove(snapshot.id)
      ..[snapshot.id] = snapshot;
    _evict();
    return snapshot;
  }

  /// Возвращает страницу только из своего чата; истёкшие удаляются.
  PageSnapshot? get(String chatId, String pageId) {
    final pages = _chats[chatId];
    if (pages == null) return null;
    final snapshot = pages.remove(pageId);
    if (snapshot == null) return null;
    final now = _now();
    if (now.difference(snapshot.createdAt) > ttl) {
      _evict();
      return null;
    }
    final touched = snapshot.touch(now);
    pages[pageId] = touched;
    _evict();
    return touched;
  }

  /// Обновляет представление страницы, сохраняя её идентификатор.
  PageSnapshot? replaceView(
    String chatId,
    String pageId, {
    required String mode,
    required String text,
    required List<PageOutlineEntry> outline,
  }) {
    final pages = _chats[chatId];
    final current = pages?.remove(pageId);
    if (current == null) return null;
    final now = _now();
    if (now.difference(current.createdAt) > ttl) {
      _evict();
      return null;
    }
    final updated = current.withView(
      mode: mode,
      text: text,
      outline: outline,
      lastAccess: now,
    );
    pages![pageId] = updated;
    _evict();
    return updated;
  }

  /// Количество страниц во всех чатах. Нужно тестам и диагностике.
  int get length => _chats.values.fold(0, (sum, pages) => sum + pages.length);

  void _evict() {
    final now = _now();
    for (final pages in _chats.values.toList()) {
      pages.removeWhere((_, page) => now.difference(page.createdAt) > ttl);
    }
    for (final pages in _chats.values.toList()) {
      while (pages.length > maxPagesPerChat) {
        pages.remove(pages.keys.first);
      }
    }
    while (length > maxPagesTotal) {
      _removeOldest();
    }
    while (_totalChars > maxCharsTotal || _totalHtml > maxHtmlTotal) {
      if (!_removeOldest()) break;
    }
  }

  bool _removeOldest() {
    PageSnapshot? oldest;
    String? oldestChat;
    for (final entry in _chats.entries) {
      for (final page in entry.value.values) {
        if (oldest == null || page.lastAccess.isBefore(oldest.lastAccess)) {
          oldest = page;
          oldestChat = entry.key;
        }
      }
    }
    if (oldest == null || oldestChat == null) return false;
    _chats[oldestChat]!.remove(oldest.id);
    return true;
  }

  int get _totalChars => _chats.values.fold(
    0,
    (sum, pages) => sum + pages.values.fold(0, (s, p) => s + p.charCount),
  );

  int get _totalHtml => _chats.values.fold(
    0,
    (sum, pages) =>
        sum + pages.values.fold(0, (s, p) => s + p.cleanedHtml.length),
  );
}

/// Последние результаты поиска в чате: по ним модель открывает страницы по
/// короткому `ref`, не повторяя URL.
final class SearchSessionStore {
  SearchSessionStore({
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 30),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration ttl;
  final _byChat = <String, _SearchSession>{};

  void put(String chatId, List<SearchResult> results) {
    _byChat[chatId] = _SearchSession(results: results, createdAt: _now());
  }

  /// Возвращает результат по `1`, `[1]` или `s1`. Null — ссылка устарела.
  SearchResult? resolve(String chatId, String ref) {
    final session = _byChat[chatId];
    if (session == null) return null;
    if (_now().difference(session.createdAt) > ttl) {
      _byChat.remove(chatId);
      return null;
    }
    final value = ref.replaceAll(RegExp(r'[^0-9]'), '');
    final index = int.tryParse(value);
    if (index == null || index < 1 || index > session.results.length) {
      return null;
    }
    return session.results[index - 1];
  }

  List<SearchResult> results(String chatId) {
    final session = _byChat[chatId];
    if (session == null) return const [];
    if (_now().difference(session.createdAt) > ttl) return const [];
    return session.results;
  }
}

final class _SearchSession {
  const _SearchSession({required this.results, required this.createdAt});

  final List<SearchResult> results;
  final DateTime createdAt;
}
