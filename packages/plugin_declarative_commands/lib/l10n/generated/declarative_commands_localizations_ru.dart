// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'declarative_commands_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class DeclarativeCommandsLocalizationsRu
    extends DeclarativeCommandsLocalizations {
  DeclarativeCommandsLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get pluginTitle => 'Декларативные команды';

  @override
  String get pluginDescription =>
      'Превращает фиксированные команды в инструменты, которые может вызывать модель.';

  @override
  String get settingsTitle => 'Команды';

  @override
  String get settingsHint =>
      'Каждая команда становится инструментом. Модель может вызвать её, но не может изменить исполняемый файл или фиксированные аргументы.';

  @override
  String get addCommand => 'Добавить команду';

  @override
  String get emptyTitle => 'Команд нет';

  @override
  String get emptyMessage =>
      'Добавьте команду, чтобы она стала доступна модели.';

  @override
  String get editCommand => 'Изменить команду';

  @override
  String get newCommand => 'Новая команда';

  @override
  String get name => 'Название';

  @override
  String get description => 'Описание';

  @override
  String get executable => 'Исполняемый файл';

  @override
  String get arguments => 'Аргументы';

  @override
  String get argumentsHint => 'По одному аргументу на строку';

  @override
  String get timeout => 'Таймаут, секунды';

  @override
  String get invalidName => 'Введите название.';

  @override
  String get invalidExecutable => 'Введите исполняемый файл.';

  @override
  String get invalidTimeout => 'Введите положительный таймаут.';

  @override
  String get deleteTitle => 'Удалить команду';

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
  String commandCount(int count) {
    return 'Команд: $count';
  }
}
