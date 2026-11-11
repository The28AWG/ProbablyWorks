import 'package:material_ui/material_ui.dart';

/// Страница приложения: Scaffold с ограничением ширины содержимого по центру.
/// [maxWidth] = null — содержимое занимает всю ширину (например, лента чата сама ограничивает себя).
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.body,
    this.appBar,
    this.maxWidth,
    this.floatingActionButton,
    this.drawer,
    this.bottomNavigationBar,
    super.key,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final double? maxWidth;
  final Widget? floatingActionButton;
  final Widget? drawer;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    final width = maxWidth;
    return Scaffold(
      appBar: appBar,
      drawer: drawer,
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      body: SafeArea(
        child: width == null
            ? body
            : Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width),
                  child: body,
                ),
              ),
      ),
    );
  }
}
