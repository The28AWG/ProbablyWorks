import 'package:auto_route/auto_route.dart';

/// Вкладка «Проекты»: контейнер вложенного стека со списком и карточкой проекта.
///
/// Вкладка остаётся в стартовой сборке: она нужна оболочке рабочей области
/// сразу. Список проектов внутри загружается отдельно.
@RoutePage()
class ProjectsTabPage extends AutoRouter {
  const ProjectsTabPage({super.key});
}
