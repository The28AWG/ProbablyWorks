import 'package:app_ui/src/theme/app_colors.dart';
import 'package:app_ui/src/theme/app_theme.dart';
import 'package:app_ui/src/theme/app_tokens.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_widget/markdown_widget.dart';
import 'package:material_ui/material_ui.dart';

/// Markdown ответа агента в цветах и типографике текущей темы.
///
/// Единственный способ показать Markdown в приложении. `MarkdownBlock` без конфига
/// рисует светлую палитру пакета (чёрный текст, светлые блоки кода, синие ссылки),
/// поэтому в тёмной теме текст становится нечитаемым.
///
/// `markdown_widget` собран на `package:flutter/material.dart`. Его `InkWell`
/// (ссылка вокруг виджета, картинка) ищет `Material` того же пакета, а `Scaffold`
/// приложения даёт `Material` из `material_ui` — для чернил это другой тип.
/// `MaterialUiCompatibilityBridge` переносит тему, прозрачный `Material` — предок
/// для чернил. Мост временный: его уберут, когда пакет перейдёт на `material_ui`.
class AppMarkdown extends StatelessWidget {
  const AppMarkdown({required this.data, super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ignore: deprecated_member_use, markdown_widget ещё импортирует package:flutter/material.dart
    return MaterialUiCompatibilityBridge(
      child: legacy.Material(
        type: legacy.MaterialType.transparency,
        child: DefaultTextStyle.merge(
          // Базовый текст идёт через DefaultTextStyle, а не через стиль абзаца: стиль абзаца
          // родительский для ссылок, и его шрифт перебивал бы их оформление.
          style: _bodyStyle(theme),
          child: MarkdownBlock(
            data: data,
            config: _markdownConfig(context),
            generator: _markdownGenerator(theme),
          ),
        ),
      ),
    );
  }
}

/// Inline-код рисуется отдельным виджетом: `TextStyle.backgroundColor` не умеет скруглять углы.
MarkdownGenerator _markdownGenerator(ThemeData theme) {
  final scheme = theme.colorScheme;
  final style = TextStyle(
    fontFamily: AppTheme.monoFamily,
    fontSize: 13,
    color: scheme.onSurface,
  );
  return MarkdownGenerator(
    generators: [
      SpanNodeGeneratorWithTag(
        tag: MarkdownTag.code.name,
        generator: (element, config, visitor) => _InlineCodeNode(
          element.textContent,
          textStyle: style,
          background: scheme.surfaceContainerHighest,
        ),
      ),
      SpanNodeGeneratorWithTag(
        tag: MarkdownTag.pre.name,
        generator: (element, config, visitor) =>
            _AppPreBlockNode(element, config.pre, visitor),
      ),
    ],
  );
}

/// Блок ``` без языка даёт `<code>` без `class`; пакетный [CodeBlockNode] падает на `!`
/// и пишет в консоль `get language error:Null check operator used on a null value`.
class _AppPreBlockNode extends CodeBlockNode {
  _AppPreBlockNode(super.element, super.preConfig, super.visitor);

  @override
  InlineSpan build() {
    final language = _fenceHighlightLanguage(element);
    final splitContents = content.trim().split(
      visitor.splitRegExp ?? WidgetVisitor.defaultSplitRegExp,
    );
    if (splitContents.last.isEmpty) splitContents.removeLast();
    final codeBuilder = preConfig.builder;
    if (codeBuilder != null) {
      return WidgetSpan(child: codeBuilder.call(content, language ?? ''));
    }
    final widget = Container(
      decoration: preConfig.decoration,
      margin: preConfig.margin,
      padding: preConfig.padding,
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(splitContents.length, (index) {
            final currentContent = splitContents[index];
            return ProxyRichText(
              TextSpan(
                children: highLightSpans(
                  currentContent,
                  language: language ?? preConfig.language,
                  theme: preConfig.theme,
                  textStyle: style,
                  styleNotMatched: preConfig.styleNotMatched,
                ),
              ),
              richTextBuilder: visitor.richTextBuilder,
            );
          }),
        ),
      ),
    );
    return WidgetSpan(
      child: preConfig.wrapper?.call(widget, content, language ?? '') ?? widget,
    );
  }
}

String? _fenceHighlightLanguage(md.Element pre) {
  final first = pre.children?.first;
  if (first is! md.Element) return null;
  final className = first.attributes['class'];
  if (className == null || className.isEmpty) return null;
  return className.split('-').last;
}

class _InlineCodeNode extends SpanNode {
  _InlineCodeNode(
    this.text, {
    required this.textStyle,
    required this.background,
  });

  final String text;
  final TextStyle textStyle;
  final Color background;

  @override
  InlineSpan build() => WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.smAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: 2,
        ),
        child: Text(text, style: textStyle),
      ),
    ),
  );
}

TextStyle _bodyStyle(ThemeData theme) =>
    (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      color: theme.colorScheme.onSurface,
    );

MarkdownConfig _markdownConfig(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final text = theme.textTheme;
  final colors = context.appColors;

  final body = _bodyStyle(theme);
  // Цвет кода не задаём в textStyle блока: пакет накладывает его поверх цветов подсветки.
  // Цвет по умолчанию идёт через styleNotMatched.
  const monoFont = TextStyle(
    fontFamily: AppTheme.monoFamily,
    fontSize: 13,
    height: 1.5,
  );
  final mono = monoFont.copyWith(color: colors.codeText);
  final divider = HeadingDivider(color: scheme.outlineVariant);

  return MarkdownConfig(
    configs: [
      // Пустой стиль абзаца: см. комментарий в AppMarkdown.build.
      const PConfig(textStyle: TextStyle()),
      _Heading(
        tag: MarkdownTag.h1.name,
        style: (text.headlineSmall ?? const TextStyle()).copyWith(
          color: scheme.onSurface,
        ),
        divider: divider,
      ),
      _Heading(
        tag: MarkdownTag.h2.name,
        style: (text.titleLarge ?? const TextStyle()).copyWith(
          color: scheme.onSurface,
        ),
        divider: divider,
      ),
      _Heading(
        tag: MarkdownTag.h3.name,
        style: (text.titleMedium ?? const TextStyle()).copyWith(
          color: scheme.onSurface,
        ),
        divider: divider,
      ),
      for (final tag in [MarkdownTag.h4, MarkdownTag.h5, MarkdownTag.h6])
        _Heading(
          tag: tag.name,
          style: (text.titleSmall ?? const TextStyle()).copyWith(
            color: scheme.onSurface,
          ),
        ),
      PreConfig(
        theme: _codeTheme,
        textStyle: monoFont,
        // Токены без класса подсветки берут этот стиль, иначе текст наследует цвет
        // темы и на тёмной поверхности кода становится невидимым.
        styleNotMatched: mono,
        decoration: BoxDecoration(
          color: colors.codeSurface,
          borderRadius: AppRadius.mdAll,
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      ),
      LinkConfig(
        style: TextStyle(
          color: scheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: scheme.primary,
        ),
      ),
      BlockquoteConfig(
        sideColor: scheme.outline,
        textColor: scheme.onSurfaceVariant,
      ),
      ListConfig(
        marker: (isOrdered, depth, index) => isOrdered
            ? Padding(
                padding: const EdgeInsets.only(top: 1, right: AppSpacing.xs),
                child: Align(
                  alignment: Alignment.topRight,
                  child: Text('${index + 1}.', style: body),
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(top: 9),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 6),
                ),
              ),
      ),
      HrConfig(color: scheme.outlineVariant),
      TableConfig(
        border: TableBorder.all(color: scheme.outlineVariant),
        headerRowDecoration: BoxDecoration(color: scheme.surfaceContainerHigh),
        headerStyle: body.copyWith(fontWeight: FontWeight.w600),
        bodyStyle: body,
      ),
    ],
  );
}

/// Заголовок с цветом темы. Делит разделитель со стандартными `H1Config`–`H3Config`,
/// но получает цвет разделителя из схемы, а не из жёсткого `Color(0xFFd7dde3)`.
class _Heading extends HeadingConfig {
  const _Heading({required this.tag, required this.style, this.divider});

  @override
  final String tag;

  @override
  final TextStyle style;

  @override
  final HeadingDivider? divider;
}

/// Подсветка кода для тёмной поверхности блоков кода (`AppColors.codeSurface` всегда тёмная).
const _codeTheme = <String, TextStyle>{
  'keyword': TextStyle(color: Color(0xFFC4A7FF)),
  'literal': TextStyle(color: Color(0xFFFCA5A5)),
  'built_in': TextStyle(color: Color(0xFF93C5FD)),
  'type': TextStyle(color: Color(0xFF93C5FD)),
  'title': TextStyle(color: Color(0xFF7DD3FC)),
  'function': TextStyle(color: Color(0xFF7DD3FC)),
  'string': TextStyle(color: Color(0xFF86EFAC)),
  'number': TextStyle(color: Color(0xFFFBBF24)),
  'comment': TextStyle(color: Color(0xFF6B7280), fontStyle: FontStyle.italic),
  'attr': TextStyle(color: Color(0xFF7DD3FC)),
  'meta': TextStyle(color: Color(0xFF9CA3AF)),
  'symbol': TextStyle(color: Color(0xFFFBBF24)),
  'tag': TextStyle(color: Color(0xFFF87171)),
  'name': TextStyle(color: Color(0xFFF87171)),
  'params': TextStyle(color: Color(0xFFE5E7EB)),
};
