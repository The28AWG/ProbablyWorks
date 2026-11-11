// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'declarative_http_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class DeclarativeHttpLocalizationsRu extends DeclarativeHttpLocalizations {
  DeclarativeHttpLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get pluginTitle => 'Декларативные HTTP';

  @override
  String get pluginDescription =>
      'Превращает HTTP-запросы в инструменты, которые может вызывать модель.';

  @override
  String get settingsTitle => 'HTTP-инструменты';

  @override
  String get settingsHint =>
      'Инструменты вызывают фиксированные HTTP-endpoint\'ы. В URL, заголовках и теле можно использовать подстановки аргументов.';

  @override
  String get addTool => 'Добавить HTTP-инструмент';

  @override
  String get emptyTitle => 'HTTP-инструментов нет';

  @override
  String get emptyMessage =>
      'Добавьте HTTP-инструмент, чтобы он стал доступен модели.';

  @override
  String get newTool => 'Новый HTTP-инструмент';

  @override
  String get editTool => 'Изменить HTTP-инструмент';

  @override
  String get name => 'Название';

  @override
  String get description => 'Описание';

  @override
  String get method => 'Метод';

  @override
  String get url => 'URL';

  @override
  String get headers => 'Заголовки';

  @override
  String get headersHint => 'KEY=VALUE, по одному на строку';

  @override
  String get body => 'Тело';

  @override
  String get bodyHint => 'JSON или текст; пусто — без тела';

  @override
  String get inputSchema => 'Схема аргументов';

  @override
  String get inputSchemaHint => 'Объект JSON Schema';

  @override
  String get responseFormat => 'Ответ';

  @override
  String get responseText => 'Текст';

  @override
  String get responseJson => 'JSON';

  @override
  String get responseHtml => 'HTML';

  @override
  String get jsonPath => 'JSONPath';

  @override
  String get jsonPathHint => 'Необязательно, например \$.items[*].name';

  @override
  String get htmlSelector => 'CSS-селектор';

  @override
  String get htmlSelectorHint => 'Необязательно, например article .title';

  @override
  String get timeout => 'Таймаут, секунды';

  @override
  String get maxResponseChars => 'Максимум символов ответа';

  @override
  String get invalidName => 'Введите название.';

  @override
  String get invalidUrl => 'Введите корректный http(s) URL.';

  @override
  String get invalidMethod => 'Используйте GET, POST, PUT, PATCH или DELETE.';

  @override
  String get invalidBody => 'Тело должно быть корректным JSON или текстом.';

  @override
  String get invalidSchema => 'Схема аргументов должна быть JSON-объектом.';

  @override
  String get invalidTimeout => 'Введите положительный таймаут.';

  @override
  String get invalidMaxChars => 'Введите положительный лимит.';

  @override
  String get deleteTitle => 'Удалить HTTP-инструмент';

  @override
  String deleteConfirm(String name) {
    return 'Удалить «$name»?';
  }

  @override
  String get delete => 'Удалить';

  @override
  String get edit => 'Изменить';

  @override
  String get cancel => 'Отмена';

  @override
  String get save => 'Сохранить';

  @override
  String toolCount(int count) {
    return 'Инструментов: $count';
  }
}
