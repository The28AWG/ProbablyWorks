import 'dart:io';

/// Аргументы командной строки демона.
final class DaemonOptions {
  const DaemonOptions({
    this.dataDir,
    this.port = 7787,
    this.bind,
    this.printToken = false,
    this.rotateToken = false,
    this.allowedOrigins = const [],
    this.help = false,
  });

  factory DaemonOptions.fromArgs(List<String> args) {
    String? dataDir;
    var port = 7787;
    InternetAddress? bind;
    var printToken = false;
    var rotateToken = false;
    final allowedOrigins = <String>[];
    var help = false;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--data-dir':
          dataDir = _value(args, ++i, '--data-dir');
        case '--port':
          final raw = _value(args, ++i, '--port');
          final parsed = int.tryParse(raw);
          if (parsed == null || parsed < 0 || parsed > 65535) {
            throw FormatException('invalid --port: $raw');
          }
          port = parsed;
        case '--bind':
          final raw = _value(args, ++i, '--bind');
          bind = InternetAddress.tryParse(raw);
          if (bind == null) throw FormatException('invalid --bind: $raw');
        case '--print-token':
          printToken = true;
        case '--rotate-token':
          rotateToken = true;
        case '--allow-origin':
          final raw = _value(args, ++i, '--allow-origin');
          final uri = Uri.tryParse(raw);
          if (uri == null ||
              (uri.scheme != 'http' && uri.scheme != 'https') ||
              uri.host.isEmpty ||
              (uri.path.isNotEmpty && uri.path != '/')) {
            throw FormatException('invalid --allow-origin: $raw');
          }
          allowedOrigins.add(uri.origin);
        case '--help':
        case '-h':
          help = true;
        default:
          throw FormatException('unknown argument: ${args[i]}');
      }
    }
    return DaemonOptions(
      dataDir: dataDir,
      port: port,
      bind: bind,
      printToken: printToken || rotateToken,
      rotateToken: rotateToken,
      allowedOrigins: allowedOrigins,
      help: help,
    );
  }

  final String? dataDir;
  final int port;
  final InternetAddress? bind;
  final bool printToken;
  final bool rotateToken;

  /// Origin'ы браузера, которым разрешены CORS-запросы к API.
  final List<String> allowedOrigins;
  final bool help;

  static String _value(List<String> args, int index, String name) {
    if (index >= args.length) {
      throw FormatException('$name requires a value');
    }
    return args[index];
  }

  static const usage = '''
ProbablyWorks headless daemon

Usage: pw_server [options]

  --data-dir <path>  data directory (default: platform app support)
  --port <port>      API port (default: 7787)
  --bind <address>   bind address (default: 127.0.0.1)
  --print-token      print the API token on stdout
  --rotate-token     issue a new API token and print it
  --allow-origin <origin>
                     allow browser CORS from this origin (repeatable)
  -h, --help         show this help

The API is loopback-only by default. Expose it remotely only through
an SSH tunnel, VPN or a TLS reverse proxy with the token.
''';
}
