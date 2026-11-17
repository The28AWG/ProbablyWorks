import 'package:html/dom.dart' as dom;
import 'package:plugin_web_core/src/fetch/page_document.dart';

/// Результат преобразования DOM в Markdown.
final class MarkdownResult {
  const MarkdownResult({required this.text, required this.outline});

  final String text;
  final List<PageOutlineEntry> outline;
}

/// Преобразует очищенный DOM в Markdown и попутно собирает оглавление.
///
/// Нам нужны текстовые данные и структура, а не внешний вид: заголовки,
/// списки, таблицы, код и ссылки сохраняются, стили и раскладка — нет.
final class MarkdownWriter {
  const MarkdownWriter();

  MarkdownResult write(dom.Element root, {required String baseUrl}) {
    final buffer = _TextBuffer();
    final outline = <PageOutlineEntry>[];
    _blocks(root, buffer, outline, baseUrl, 0);
    final text = _trim(buffer.toString());
    return MarkdownResult(
      text: text,
      outline: [
        for (final entry in outline)
          if (entry.offset < text.length) entry,
      ],
    );
  }

  static const _skip = {
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'canvas',
    'iframe',
    'form',
    'button',
    'input',
    'select',
    'textarea',
    'nav',
    'footer',
    'aside',
  };

  void _blocks(
    dom.Node node,
    _TextBuffer out,
    List<PageOutlineEntry> outline,
    String baseUrl,
    int indent,
  ) {
    if (node is dom.Text) {
      final text = _inlineText(node.text);
      if (text.isNotEmpty) {
        out
          ..write(text)
          ..write('\n\n');
      }
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName ?? '';
    if (_skip.contains(tag)) return;
    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(tag[1]);
        out.ensureGap();
        outline.add(
          PageOutlineEntry(
            level: level,
            title: _inline(node, baseUrl).trim(),
            offset: out.length,
          ),
        );
        out
          ..write('#' * level)
          ..write(' ')
          ..write(_inline(node, baseUrl).trim())
          ..write('\n\n');
        break;
      case 'p':
        final text = _inline(node, baseUrl).trim();
        if (text.isNotEmpty) {
          out
            ..ensureGap()
            ..write(text)
            ..write('\n\n');
        }
        break;
      case 'ul':
      case 'ol':
        _list(node, out, baseUrl, indent, ordered: tag == 'ol');
        out.write('\n');
        break;
      case 'pre':
        final code = node.text.trimRight();
        if (code.isNotEmpty) {
          out.ensureGap();
          final language = _languageOf(node);
          out
            ..write('```')
            ..write(language)
            ..write('\n')
            ..write(code)
            ..write('\n```\n\n');
        }
        break;
      case 'blockquote':
        final inner = _TextBuffer();
        _blocks(node, inner, outline, baseUrl, indent);
        final quoted = _trim(inner.toString())
            .split('\n')
            .map((line) => line.isEmpty ? '>' : '> $line')
            .join('\n');
        if (quoted.isNotEmpty) {
          out
            ..ensureGap()
            ..write(quoted)
            ..write('\n\n');
        }
        break;
      case 'table':
        final table = _table(node, baseUrl);
        if (table.isNotEmpty) {
          out
            ..ensureGap()
            ..write(table)
            ..write('\n\n');
        }
        break;
      case 'hr':
        out
          ..ensureGap()
          ..write('---\n\n');
        break;
      case 'br':
        out.write('\n');
        break;
      case 'img':
        final image = _image(node, baseUrl);
        if (image.isNotEmpty) out.write('$image ');
        break;
      default:
        final isInline = _inlineTags.contains(tag);
        if (isInline) {
          final text = _inline(node, baseUrl);
          if (text.isNotEmpty) {
            out.write(text);
            if (tag == 'a') out.write('\n\n');
          }
        } else {
          for (final child in node.nodes) {
            _blocks(child, out, outline, baseUrl, indent);
          }
        }
    }
  }

  void _list(
    dom.Element node,
    _TextBuffer out,
    String baseUrl,
    int indent, {
    required bool ordered,
  }) {
    out.ensureGap();
    var index = 1;
    for (final item in node.children.where(
      (child) => child.localName == 'li',
    )) {
      final marker = ordered ? '$index. ' : '- ';
      final text = _inline(item, baseUrl).trim();
      out
        ..write('  ' * indent)
        ..write(marker)
        ..write(text)
        ..write('\n');
      for (final nested in item.children.where(
        (child) => child.localName == 'ul' || child.localName == 'ol',
      )) {
        _list(
          nested,
          out,
          baseUrl,
          indent + 1,
          ordered: nested.localName == 'ol',
        );
      }
      index++;
    }
  }

  String _table(dom.Element node, String baseUrl) {
    final rows = <List<String>>[];
    for (final row in node.querySelectorAll('tr')) {
      final cells = <String>[];
      for (final cell in row.children.where(
        (child) => child.localName == 'th' || child.localName == 'td',
      )) {
        cells.add(
          _inline(
            cell,
            baseUrl,
          ).replaceAll('|', r'\|').replaceAll('\n', ' ').trim(),
        );
      }
      if (cells.isEmpty) continue;
      rows.add(cells);
    }
    if (rows.isEmpty) return '';
    final columns = rows
        .map((row) => row.length)
        .fold(0, (a, b) => a > b ? a : b);
    if (columns == 0) return '';
    final width = columns;
    String line(List<String> cells) {
      final values = [...cells];
      while (values.length < width) {
        values.add('');
      }
      return '| ${values.join(' | ')} |';
    }

    final buffer = StringBuffer()
      ..writeln(line(rows.first))
      ..writeln('| ${List.filled(width, '---').join(' | ')} |');
    for (final row in rows.skip(1)) {
      buffer.writeln(line(row));
    }
    return _trim(buffer.toString());
  }

  String _inline(dom.Node node, String baseUrl) {
    if (node is dom.Text) return _inlineText(node.text);
    if (node is! dom.Element) return '';
    final tag = node.localName ?? '';
    if (_skip.contains(tag)) return '';
    final children = node.nodes.map((child) => _inline(child, baseUrl)).join();
    return switch (tag) {
      'strong' ||
      'b' => children.trim().isEmpty ? '' : '**${children.trim()}**',
      'em' || 'i' => children.trim().isEmpty ? '' : '*${children.trim()}*',
      'code' => children.trim().isEmpty ? '' : '`${children.trim()}`',
      'del' || 's' => children.trim().isEmpty ? '' : '~~${children.trim()}~~',
      'br' => '\n',
      'img' => _image(node, baseUrl),
      'a' => _link(node, children, baseUrl),
      _ => children,
    };
  }

  String _link(dom.Element node, String children, String baseUrl) {
    final href = node.attributes['href'];
    final text = children.trim();
    if (href == null || href.isEmpty) return children;
    if (text.isEmpty) return '';
    final resolved = _resolve(href, baseUrl);
    return '[$text]($resolved)';
  }

  String _image(dom.Element node, String baseUrl) {
    final alt = (node.attributes['alt'] ?? '').trim();
    final src = (node.attributes['src'] ?? '').trim();
    if (src.isEmpty) return alt;
    return '![${alt.isEmpty ? 'image' : alt}](${_resolve(src, baseUrl)})';
  }

  static String _resolve(String href, String baseUrl) {
    final uri = Uri.tryParse(href);
    if (uri == null) return href;
    if (uri.hasScheme) return href;
    final base = Uri.tryParse(baseUrl);
    if (base == null) return href;
    return base.resolveUri(uri).toString();
  }

  static String _languageOf(dom.Element node) {
    final code = node.querySelector('code');
    final className = code?.attributes['class'] ?? '';
    final match = RegExp(r'language-([A-Za-z0-9_+-]+)').firstMatch(className);
    return match?.group(1) ?? '';
  }

  static String _inlineText(String value) =>
      value.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'[ \t\r\n]+'), ' ');

  /// Не трогает внутренние пустые строки и отступы: они могут быть частью
  /// блока кода. Разделители блоков уже ограничены [_TextBuffer.ensureGap].
  static String _trim(String value) => value.trim();
}

/// Буфер Markdown с учётом хвостовых переводов строк.
///
/// `_ensureGap` не должен вызывать `toString()` на каждом блоке: для длинной
/// страницы это квадратично по объёму текста. Буфер хранит число хвостовых
/// переводов строк и добавляет ровно один разделитель.
final class _TextBuffer {
  final _buffer = StringBuffer();
  var _newlines = 0;

  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;

  void write(String value) {
    if (value.isEmpty) return;
    _buffer.write(value);
    final trailing = _trailingNewlines(value);
    _newlines = trailing == value.length
        ? (_newlines + trailing > 2 ? 2 : _newlines + trailing)
        : trailing;
  }

  void writeln(String value) => write('$value\n');

  void ensureGap() {
    if (isEmpty || _newlines >= 2) return;
    write(_newlines == 1 ? '\n' : '\n\n');
  }

  @override
  String toString() => _buffer.toString();

  static int _trailingNewlines(String value) {
    if (value.endsWith('\n\n')) return 2;
    if (value.endsWith('\n')) return 1;
    return 0;
  }
}

const _inlineTags = {
  'a',
  'abbr',
  'b',
  'bdi',
  'bdo',
  'br',
  'cite',
  'code',
  'data',
  'del',
  'dfn',
  'em',
  'i',
  'img',
  'ins',
  'kbd',
  'mark',
  'q',
  's',
  'samp',
  'small',
  'span',
  'strong',
  'sub',
  'sup',
  'time',
  'u',
  'var',
};
