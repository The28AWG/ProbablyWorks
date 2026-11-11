import 'dart:io';

/// Аргументы командной строки демона.
final class DaemonOptions {
  const DaemonOptions({
    this.dataDir,
    this.port = 7787,
    this.bind,
    this.printToken = false,
    this.rotateToken = false,
    this.help = false,
  });

  factory DaemonOptions.fromArgs(List<String> args) {
    String? dataDir;
    var port = 7787;
    InternetAddress? bind;
    var printToken = false;
    var rotateToken = false;
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
      help: help,
    );
  }

  final String? dataDir;
  final int port;
  final InternetAddress? bind;
  final bool printToken;
  final bool rotateToken;
  final bool help;

  static String _value(List<String> args, int index, String name) {
    if (index >= args.length) {
      throw FormatException('$name requires a value');
    }
    return args[index];
  }

  static const usage = '''
ProbablyWorks headless daemon

Usage: pw_daemon [options]

  --data-dir <path>  data directory (default: platform app support)
  --port <port>      API port (default: 7787)
  --bind <address>   bind address (default: 127.0.0.1)
  --print-token      print the API token on stdout
  --rotate-token     issue a new API token and print it
  -h, --help         show this help

The API is loopback-only by default. Expose it remotely only through
an SSH tunnel, VPN or a TLS reverse proxy with the token.
''';
}
