import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// Список сверху вниз, который сам держит позицию. Ни один кадр не показывается с «уехавшим» содержимым:
/// вся коррекция прокрутки считается в layout, до отрисовки, через [SliverGeometry.scrollOffsetCorrection].
///
/// Два режима:
/// * читаем историю — верхний видимый элемент (якорь) остаётся на месте, как бы ни менялась высота
///   того, что над ним, а рост под ним просто уходит вниз;
/// * следим за концом ([following]) — при появлении нового содержимого в конце прокрутка едет вниз,
///   чтобы конец оставался виден. Рост внутри ленты (например, раскрытие блока) не трогает прокрутку:
///   блок растёт вниз, его заголовок стоит на месте.
class AnchoredSliverList extends SliverMultiBoxAdaptorWidget {
  const AnchoredSliverList({
    required this.following,
    required super.delegate,
    super.key,
  });

  /// Следим за концом ленты: при появлении нового содержимого прокрутка едет вниз.
  final bool following;

  @override
  RenderSliverList createRenderObject(BuildContext context) {
    final element = context as SliverMultiBoxAdaptorElement;
    return _RenderAnchoredSliverList(
      childManager: element,
      following: following,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderSliverList renderObject) {
    (renderObject as _RenderAnchoredSliverList).following = following;
  }
}

class _RenderAnchoredSliverList extends RenderSliverList {
  _RenderAnchoredSliverList({
    required super.childManager,
    required bool following,
  }) : _following = following,
       _snap = following;

  bool _following;

  /// Слежение включили: ставим конец сразу, без сравнения с прошлым кадром.
  bool _snap;

  /// Верхний видимый элемент и его смещение в содержимом на прошлом проходе.
  RenderBox? _anchor;
  double _anchorOffset = 0;

  /// Размер содержимого и смещение последнего элемента на прошлом полном проходе.
  double? _prevExtent;
  double? _prevTail;

  set following(bool value) {
    if (_following == value) return;
    _following = value;
    if (value) _snap = true;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    // Список сам попросил коррекцию (например, убрали элемент над экраном): пересчёт сделает viewport.
    if (geometry!.scrollOffsetCorrection != null) return;
    final correction = _correction();
    if (correction != 0) {
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
    }
  }

  /// Сколько прокрутить, чтобы положение видимого содержимого не менялось, кроме случая слежения за концом.
  double _correction() {
    final extent = geometry!.scrollExtent;
    final last = lastChild;
    final count = childManager.childCount;
    // Конец построен, только когда последний построенный элемент — последний в списке. Тогда размер
    // содержимого точный. До этого размер — оценка по уже построенным элементам, он меняется с прокруткой.
    final reachedEnd = last != null && indexOf(last) == count - 1;

    // Изменение якоря с прошлого прохода: всё, что случилось над ним, сдвигает его на эту дельту.
    var anchorDelta = 0.0;
    final anchor = _anchor;
    final anchorNow = anchor == null || anchor.parent != this
        ? null
        : childScrollOffset(anchor);
    if (anchorNow != null) anchorDelta = anchorNow - _anchorOffset;
    // Якорь выбираем заново по текущей прокрутке: прошлый мог уйти под элемент, который сейчас меняют.
    _pickAnchor();

    final double correction;
    if (!_following) {
      correction = anchorDelta;
    } else if (!reachedEnd) {
      // Тянем прокрутку к оценке конца, пока конец не построится. Прошлые значения не запоминаем.
      _snap = false;
      _prevExtent = null;
      correction = _maxOffset(extent) - constraints.scrollOffset;
    } else {
      final tail = childScrollOffset(last)!;
      final prevExtent = _prevExtent;
      final prevTail = _prevTail;
      if (_snap || prevExtent == null || prevTail == null) {
        _snap = false;
        correction = _maxOffset(extent) - constraints.scrollOffset;
      } else {
        // Рост после якоря и в конце (новое сообщение, текст стримится) едет вниз. Рост между якорем и концом
        // (раскрытие блока внутри ленты) не считаем: блок растёт вниз, заголовок стоит на месте.
        correction = (extent - prevExtent) - (tail - prevTail) + anchorDelta;
      }
      _prevExtent = extent;
      _prevTail = tail;
    }
    return correction.abs() < 0.5 ? 0 : correction;
  }

  /// Верхний видимый элемент: первый, чей низ ниже верхнего края окна.
  void _pickAnchor() {
    _anchor = null;
    var child = firstChild;
    while (child != null) {
      final offset = childScrollOffset(child);
      if (offset != null &&
          offset + paintExtentOf(child) > constraints.scrollOffset) {
        _anchor = child;
        _anchorOffset = offset;
        return;
      }
      child = childAfter(child);
    }
  }

  /// Смещение, при котором виден конец содержимого.
  double _maxOffset(double extent) =>
      (extent - constraints.viewportMainAxisExtent).clamp(0.0, double.infinity);
}
