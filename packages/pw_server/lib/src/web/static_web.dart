import 'dart:io';

import 'package:path/path.dart' as p;

/// Раздача статической web-сборки поверх того же HTTP-сервера, что и API.
///
/// Класс не знает про аутентификацию: его вызывает [ApiServer] до проверки
/// токена. Поэтому web-клиент открывается без Bearer-токена, а API остаётся
/// защищённым. Пути `/api/**` сюда не попадают.
final class StaticWeb {
  StaticWeb._(this._rootPath, {required this.spaFallback});

  /// Открывает каталог web-сборки и проверяет, что в нём есть `index.html`.
  ///
  /// Бросает [FormatException], если каталог не найден, не разрешается в
  /// канонический путь или в нём нет точки входа.
  factory StaticWeb.open(String path, {bool spaFallback = true}) {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      throw FormatException('web directory not found: $path');
    }
    final String rootPath;
    try {
      rootPath = directory.resolveSymbolicLinksSync();
    } on FileSystemException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        FormatException('cannot resolve web directory $path: ${error.message}'),
        stackTrace,
      );
    }
    if (!File(p.join(rootPath, indexFileName)).existsSync()) {
      throw FormatException('web directory has no $indexFileName: $path');
    }
    return StaticWeb._(rootPath, spaFallback: spaFallback);
  }

  /// Имя файла, который отдаётся для `/` и SPA-маршрутов.
  static const indexFileName = 'index.html';

  /// Каталоги ассетов: для них fallback на `index.html` не применяется,
  /// иначе отсутствующий файл вернул бы HTML с неправильным Content-Type.
  static const _assetRoots = {'assets', 'canvaskit', 'icons'};

  static const _entryPoints = {
    'index.html',
    'flutter.js',
    'flutter_bootstrap.js',
    'main.dart.js',
    'main.dart.wasm',
    'main.dart.mjs',
    'flutter_service_worker.js',
    'version.json',
    'manifest.json',
  };

  /// Заголовки cross-origin isolation для HTML-документа.
  ///
  /// С ними Flutter выбирает многопоточный Skwasm. На ассеты и ответы API их
  /// ставить не нужно: изоляция — свойство документа, а не отдельного файла.
  static const _crossOriginIsolationHeaders = {
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-embedder-policy': 'require-corp',
  };

  static const _contentTypes = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.map': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.txt': 'text/plain; charset=utf-8',
    '.xml': 'application/xml; charset=utf-8',
    '.bin': 'application/octet-stream',
    '.data': 'application/octet-stream',
    '.symbols': 'text/plain; charset=utf-8',
  };

  final String _rootPath;

  /// Отдавать ли `index.html` для неизвестных путей без расширения.
  final bool spaFallback;

  /// Отдаёт файл или SPA-fallback. Ответ закрывает вызывающая сторона.
  Future<void> serve(HttpRequest request, HttpResponse response) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      _text(
        request,
        response,
        HttpStatus.methodNotAllowed,
        'Method not allowed',
        allow: 'GET, HEAD',
      );
      return;
    }

    final segments = _safeSegments(request.uri.pathSegments);
    if (segments == null) {
      _text(request, response, HttpStatus.notFound, 'Not found');
      return;
    }

    final target = _targetPath(segments);
    if (target == null) {
      _text(request, response, HttpStatus.notFound, 'Not found');
      return;
    }
    final file = _fileFor(target);
    if (file != null) {
      await _serveFile(request, response, file);
      return;
    }

    if (_shouldFallback(segments)) {
      final index = _fileFor(p.join(_rootPath, indexFileName));
      if (index != null) {
        await _serveFile(request, response, index);
        return;
      }
    }
    _text(request, response, HttpStatus.notFound, 'Not found');
  }

  /// Убирает хвостовой пустой сегмент и отклоняет небезопасные сегменты.
  ///
  /// `Uri` уже нормализует часть encoded-последовательностей, но проверка
  /// нужна и после декодирования: `%2f` превращается в `/` внутри сегмента.
  List<String>? _safeSegments(List<String> raw) {
    final segments = [...raw];
    if (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    for (final segment in segments) {
      if (!_isSafeSegment(segment)) return null;
    }
    return segments;
  }

  static bool _isSafeSegment(String segment) {
    if (segment.isEmpty) return false;
    if (segment == '.' || segment == '..') return false;
    if (segment.startsWith('.')) return false;
    if (segment.contains('/') ||
        segment.contains('\\') ||
        segment.contains('\u0000')) {
      return false;
    }
    return true;
  }

  String? _targetPath(List<String> segments) {
    final relative = segments.isEmpty ? indexFileName : p.joinAll(segments);
    final candidate = p.normalize(p.join(_rootPath, relative));
    return _isInsideRoot(candidate) ? candidate : null;
  }

  /// Возвращает канонический путь файла внутри корня или null.
  ///
  /// Символические ссылки разрешаются до проверки границы: ссылка из
  /// web-каталога наружу не должна открывать произвольные файлы.
  String? _fileFor(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: true);
    if (type == FileSystemEntityType.notFound) return null;
    final candidate = type == FileSystemEntityType.directory
        ? p.join(path, indexFileName)
        : path;
    if (FileSystemEntity.typeSync(candidate, followLinks: true) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final resolved = File(candidate).resolveSymbolicLinksSync();
      return _isInsideRoot(resolved) ? resolved : null;
    } on FileSystemException {
      return null;
    }
  }

  bool _isInsideRoot(String path) =>
      p.equals(path, _rootPath) || p.isWithin(_rootPath, path);

  bool _shouldFallback(List<String> segments) {
    if (!spaFallback) return false;
    if (segments.isEmpty) return false;
    if (_assetRoots.contains(segments.first)) return false;
    return p.extension(segments.last).isEmpty;
  }

  Future<void> _serveFile(
    HttpRequest request,
    HttpResponse response,
    String path,
  ) async {
    final file = File(path);
    final stat = file.statSync();
    final etag = '"${stat.size}-${stat.modified.millisecondsSinceEpoch}"';
    final lastModified = HttpDate.format(stat.modified.toUtc());
    response.headers
      ..set(HttpHeaders.contentTypeHeader, _contentTypeFor(path))
      ..set(HttpHeaders.etagHeader, etag)
      ..set(HttpHeaders.lastModifiedHeader, lastModified)
      ..set(HttpHeaders.cacheControlHeader, _cacheControlFor(path))
      ..set('x-content-type-options', 'nosniff')
      ..set('referrer-policy', 'no-referrer');
    if (p.extension(path).toLowerCase() == '.html') {
      for (final header in _crossOriginIsolationHeaders.entries) {
        response.headers.set(header.key, header.value);
      }
    }

    if (_isNotModified(request, etag, stat.modified)) {
      response.statusCode = HttpStatus.notModified;
      return;
    }

    response.contentLength = stat.size;
    if (request.method == 'HEAD') return;
    response.bufferOutput = false;
    await response.addStream(file.openRead());
  }

  bool _isNotModified(HttpRequest request, String etag, DateTime modified) {
    final ifNoneMatch = request.headers.value(HttpHeaders.ifNoneMatchHeader);
    if (ifNoneMatch != null) {
      final tags = ifNoneMatch.split(',').map((value) => value.trim());
      if (tags.contains('*') || tags.contains(etag)) return true;
    }
    final ifModifiedSince = request.headers.value(
      HttpHeaders.ifModifiedSinceHeader,
    );
    if (ifModifiedSince == null) return false;
    try {
      final since = HttpDate.parse(ifModifiedSince);
      return !modified.toUtc().isAfter(since);
    } on Object {
      return false;
    }
  }

  static String _contentTypeFor(String path) =>
      _contentTypes[p.extension(path).toLowerCase()] ??
      'application/octet-stream';

  String _cacheControlFor(String path) {
    final relative = p
        .relative(path, from: _rootPath)
        .replaceAll(Platform.pathSeparator, '/');
    if (_entryPoints.contains(relative)) return 'no-cache';
    if (relative.startsWith('assets/') ||
        relative.startsWith('canvaskit/') ||
        relative.startsWith('icons/')) {
      return 'public, max-age=3600';
    }
    return 'no-cache';
  }

  /// Пишет текстовый ответ; для HEAD тело не отправляется.
  void _text(
    HttpRequest request,
    HttpResponse response,
    int status,
    String message, {
    String? allow,
  }) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (allow != null) response.headers.set(HttpHeaders.allowHeader, allow);
    if (request.method != 'HEAD') response.write('$message\n');
  }
}
