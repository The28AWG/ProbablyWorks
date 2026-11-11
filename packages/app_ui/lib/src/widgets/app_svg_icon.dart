import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

/// SVG-значок из `assets/` с размером и цветом [IconTheme], как у `Icon`. Значок, которого нет в Material
/// (например, логотип Linux), рисуется одним цветом: родитель задаёт его через `IconTheme`, поэтому
/// значок меняется вместе с выбором и темой так же, как Material-иконки.
class AppSvgIcon extends StatelessWidget {
  const AppSvgIcon(this.asset, {super.key});

  /// Путь к SVG в `pubspec.yaml`, например `assets/icons/os_linux.svg`.
  final String asset;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final size = iconTheme.size ?? 24;
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
