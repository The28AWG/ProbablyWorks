import 'dart:io';

import 'package:pw_agent/core/util/home_path.dart';
import 'package:pw_agent/core/util/workspace_path.dart';

/// Пути, которые не читаются автоматически: ключи, токены и credentials.
///
/// Список встроенный, а не настройка: ослаблять его через UI опаснее, чем
/// оставить фиксированным. Сравнение лексическое, без обращения к Host:
/// символические ссылки раскрывает Host, а решение о подтверждении нужно
/// принять до запуска операции.
final class SensitivePaths {
  SensitivePaths({
    required this.home,
    required this.windows,
    required this.remote,
  });

  /// Текущие пути машины. Для локального Host `~` раскрывается, для удалённого
  /// остаётся `~`: домашний каталог там другой.
  factory SensitivePaths.current({required bool remote}) {
    final environment = Platform.environment;
    return SensitivePaths(
      home: expandHomePath('~', environment: environment),
      windows: Platform.isWindows,
      remote: remote,
    );
  }

  final String home;
  final bool windows;

  /// Удалённый Host: `~` нельзя раскрыть локальным домом.
  final bool remote;

  /// Каталоги и файлы внутри домашнего каталога.
  static const _homeRoots = <String>[
    '.ssh',
    '.aws',
    '.azure',
    '.config/gcloud',
    '.config/gh',
    '.config/op',
    '.config/1password',
    '.config/sops',
    '.config/age',
    '.config/BraveSoftware',
    '.config/google-chrome',
    '.config/chromium',
    '.config/Code/User/globalStorage',
    '.mozilla',
    '.kube',
    '.gnupg',
    '.password-store',
    '.docker/config.json',
    '.local/share/keyrings',
    '.local/share/com.the28awg.probably_works',
    'Library/Keychains',
    'AppData/Roaming/gcloud',
    'AppData/Roaming/gh',
    'AppData/Roaming/1Password',
    'AppData/Roaming/op',
    'AppData/Local/Microsoft/Credentials',
    'AppData/Roaming/Microsoft/Credentials',
  ];

  /// Файлы в домашнем каталоге, которые обычно содержат токены.
  static const _homeFiles = <String>[
    '.netrc',
    '.git-credentials',
    '.npmrc',
    '.pypirc',
  ];

  /// Системные файлы, которые не должен читать агент без явного запроса.
  static const _systemRoots = <String>[
    '/etc/shadow',
    '/etc/gshadow',
    '/etc/sudoers',
    '/etc/sudoers.d',
    '/root/.ssh',
    '/root/.aws',
    '/root/.kube',
    '/Library/Keychains',
  ];

  static final _homePrefixes = <RegExp>[
    RegExp(r'^/home/[^/]+', caseSensitive: false),
    RegExp(r'^/Users/[^/]+', caseSensitive: false),
    RegExp(r'^/root', caseSensitive: false),
    RegExp(r'^[A-Za-z]:/Users/[^/]+', caseSensitive: false),
  ];

  static final _secretFile = RegExp(
    r'^(?:\.env(?:\..+)?|\.envrc|id_(?:rsa|dsa|ecdsa|ed25519)|authorized_keys)$',
    caseSensitive: false,
  );

  /// Причина, по которой путь считается чувствительным. Null — обычный путь.
  ///
  /// Для рекурсивного поиска (`grep`) дополнительно проверяется, что искомый
  /// каталог не является предком чувствительного каталога: иначе поиск по дому
  /// прочитал бы `.ssh` целиком.
  String? sensitiveReason(String path, {bool recursive = false}) {
    final normalized = _normalize(path);
    for (final root in _homeRoots) {
      if (_underHome(normalized, root)) return 'sensitive path: ~/$root';
    }
    for (final name in _homeFiles) {
      if (_baseName(normalized) == name) return 'sensitive file: $name';
    }
    if (_secretFile.hasMatch(_baseName(normalized))) {
      return 'sensitive file: ${_baseName(normalized)}';
    }
    for (final root in _systemRoots) {
      if (_isUnder(normalized, root)) return 'sensitive path: $root';
    }
    if (recursive) {
      for (final root in _homeRoots) {
        final sensitive = _normalize('~/$root');
        if (_isUnder(sensitive, normalized)) {
          return 'sensitive path inside: ~/$root';
        }
      }
    }
    return null;
  }

  /// Путь внутри рабочей папки. Для удалённого Host `~` сравнивается как `~`.
  bool isInsideWorkspace(String path, String? workspace) {
    final root = workspace?.trim();
    if (root == null || root.isEmpty) return false;
    return _isUnder(_normalize(path), _normalize(root));
  }

  bool _underHome(String path, String root) {
    if (_isUnder(path, '~/$root')) return true;
    if (_isUnder(path, '$home/$root')) return true;
    for (final prefix in _homePrefixes) {
      final match = prefix.firstMatch(path);
      if (match == null) continue;
      final full = '${match.group(0)}/$root';
      if (_isUnder(path, full)) return true;
    }
    return false;
  }

  bool _isUnder(String path, String root) {
    final normalizedPath = _normalize(path);
    final normalizedRoot = _normalize(root);
    if (normalizedRoot.isEmpty) return false;
    if (normalizedRoot == '~') {
      return normalizedPath == '~' || normalizedPath.startsWith('~/');
    }
    if (normalizedRoot == '/') return normalizedPath.startsWith('/');
    return normalizedPath == normalizedRoot ||
        normalizedPath.startsWith('$normalizedRoot/');
  }

  String _normalize(String path) {
    final expanded = _expand(path.trim());
    return normalizeWorkspacePath(expanded, windows: windows);
  }

  String _expand(String path) {
    if (remote) return path;
    final slash = path.replaceAll(r'\', '/');
    if (slash == '~') return home;
    if (slash.startsWith('~/')) return '$home/${slash.replaceFirst('~/', '')}';
    return path;
  }

  String _baseName(String path) => path.split('/').last;
}
