// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'web_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class WebLocalizationsRu extends WebLocalizations {
  WebLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get pluginTitle => 'Веб: поиск и сбор данных';

  @override
  String get pluginDescription =>
      'Поиск в интернете, чтение страниц как текста и сбор структурированных записей по CSS-селекторам.';

  @override
  String get searchSection => 'Поиск';

  @override
  String get searchSectionHint =>
      'Поиск появляется после выбора провайдера и сохранения ключа. Чтение страниц работает и без поиска.';

  @override
  String get provider => 'Провайдер';

  @override
  String get providerBrave => 'Brave';

  @override
  String get providerBraveHint => 'Собственный индекс, нужен ключ API.';

  @override
  String get providerTavily => 'Tavily';

  @override
  String get providerTavilyHint => 'Поисковый API для агентов, нужен ключ.';

  @override
  String get providerSearxng => 'SearXNG';

  @override
  String get providerSearxngHint =>
      'Свой инстанс с JSON-выдачей, ключ не нужен.';

  @override
  String get endpoint => 'Адрес';

  @override
  String get endpointHint => 'Пусто — адрес провайдера по умолчанию.';

  @override
  String get apiKey => 'Ключ API';

  @override
  String get apiKeyHint =>
      'Ключ хранится в защищённом хранилище ОС и больше не показывается.';

  @override
  String get apiKeySaved => 'Ключ сохранён';

  @override
  String get apiKeyRemove => 'Удалить ключ';

  @override
  String get apiKeyRemoved => 'Ключ API удалён';

  @override
  String get maxResults => 'Результатов по умолчанию';

  @override
  String get safeSearch => 'Безопасный поиск';

  @override
  String get language => 'Язык поиска';

  @override
  String get languageHint => 'Необязательный код языка, например en или ru.';

  @override
  String get pagesSection => 'Страницы';

  @override
  String get pagesSectionHint =>
      'Лимиты защищают контекст модели и сеть. Страница хранится как очищенный текст, а не как сырой HTML.';

  @override
  String get maxChars => 'Символов за ответ';

  @override
  String get maxBytes => 'Максимальный размер страницы, байт';

  @override
  String get timeoutSeconds => 'Таймаут, секунд';

  @override
  String get userAgent => 'User-Agent';

  @override
  String get userAgentHint =>
      'Честный User-Agent помогает сайтам понять, кто к ним пришёл.';

  @override
  String get respectRobots => 'Учитывать robots.txt';

  @override
  String get cacheTtl => 'Кэш страниц, минут';

  @override
  String get cacheNote =>
      'Страницы живут в памяти с LRU-лимитом и истекают по TTL. Перезапуск приложения очищает кэш.';

  @override
  String get domainsSection => 'Домены';

  @override
  String get domainsSectionHint =>
      'По одному домену на строку. Запрет всегда сильнее разрешения. Пустой список разрешённых означает все домены.';

  @override
  String get allowedDomains => 'Разрешённые домены';

  @override
  String get allowedDomainsHint => 'example.com\ndocs.example.com';

  @override
  String get deniedDomains => 'Запрещённые домены';

  @override
  String get deniedDomainsHint => 'ads.example.com';

  @override
  String get save => 'Сохранить';

  @override
  String get saved => 'Настройки веб-плагина сохранены';

  @override
  String saveFailed(String error) {
    return 'Не удалось сохранить настройки: $error';
  }

  @override
  String get loading => 'Загружаем настройки…';

  @override
  String get errorTitle => 'Не удалось загрузить настройки';

  @override
  String get invalidNumber => 'Введите число в допустимом диапазоне.';

  @override
  String get invalidEndpoint => 'Введите адрес http:// или https://.';

  @override
  String get invalidEndpointRequired => 'Для SearXNG нужен адрес инстанса.';

  @override
  String get searchNotConfigured =>
      'Поиск не настроен. Чтение страниц всё равно доступно.';
}
