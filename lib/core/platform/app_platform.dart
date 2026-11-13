import 'package:flutter/foundation.dart';

/// Возможности текущей платформы. Решения принимаются здесь, а не разбросаны по экранам.
class AppPlatform {
  const AppPlatform(this.target);

  /// Платформа запуска.
  // Геттер, а не const: `defaultTargetPlatform` задаётся рантаймом, поэтому конструктор не подходит.
  // ignore: prefer_constructors_over_static_methods
  static AppPlatform get current => AppPlatform(defaultTargetPlatform);

  final TargetPlatform target;

  bool get isAndroid => target == TargetPlatform.android;
  bool get isIOS => target == TargetPlatform.iOS;
  bool get isMobile => isAndroid || isIOS;

  /// Браузер. Web-сборка пока не входит в поставку, но платформенные
  /// решения не должны принимать браузер за desktop и создавать локальный Host.
  bool get isWeb => kIsWeb;

  /// Локальный Host: процессы на этом устройстве. На iOS песочница не порождает shell,
  /// а в браузере нет ни процессов, ни PTY, поэтому Host не создаётся.
  bool get hasLocalHost => !isWeb && !isIOS;

  /// Локальный PTY (portable_pty). Совпадает с [hasLocalHost]: без локального Host PTY не нужен.
  bool get hasPty => hasLocalHost;

  /// Системный выбор папки. На мобильных недоступен: рабочая папка вводится вручную или берётся из папки приложения.
  bool get supportsDirectoryPicker => !isMobile;

  /// Ключ SSH можно читать по пути на диске. На мобильных путь не нужен: ключ хранится как PEM в secure storage.
  bool get canOpenExternalKeys => !isMobile;

  /// Ставить фокус в поле ввода при открытии чата. На мобильных не ставим: фокус сразу открывает
  /// клавиатуру, которая занимает половину экрана. Курсор появится, когда пользователь коснётся поля.
  bool get focusesInputOnOpen => !isMobile;

  /// Перетаскивание файлов в окно (desktop_drop). На мобильных плагина нет, там есть кнопка прикрепления.
  bool get supportsFileDrop => !isMobile && !isWeb;
}
