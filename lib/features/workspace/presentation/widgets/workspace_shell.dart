import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/widgets/sidebar_resize_handle.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_sidebar.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Раскладка оболочки по ширине окна. Пороги из [AppBreakpoints].
enum WorkspaceLayout {
  /// Панель с чатами и навигацией постоянно слева; её можно свернуть до полосы иконок и растянуть.
  wide,

  /// Полоса иконок слева; панель с чатами и навигацией открывается как drawer.
  medium,

  /// Один экран за раз. Панель с чатами и навигацией открывается как drawer кнопкой меню в шапке страницы.
  compact;

  static WorkspaceLayout fromWidth(double width) => switch (width) {
    >= AppBreakpoints.wide => .wide,
    >= AppBreakpoints.medium => .medium,
    _ => .compact,
  };
}

class _WorkspaceLayoutScope extends InheritedWidget {
  const _WorkspaceLayoutScope({
    required this.layout,
    required this.openSidebar,
    required super.child,
  });

  final WorkspaceLayout layout;

  /// Открывает drawer с панелью. Вызывается из страниц, которые сами не знают про Scaffold оболочки.
  final VoidCallback openSidebar;

  @override
  bool updateShouldNotify(_WorkspaceLayoutScope oldWidget) =>
      layout != oldWidget.layout;
}

extension WorkspaceLayoutContext on BuildContext {
  /// Раскладка оболочки или `null`, если экран открыт вне неё (например, онбординг).
  WorkspaceLayout? get workspaceLayout =>
      dependOnInheritedWidgetOfExactType<_WorkspaceLayoutScope>()?.layout;

  /// Открывает панель с чатами и разделами как drawer. В широкой раскладке панель и так видна, поэтому не нужно.
  void openWorkspaceSidebar() =>
      getInheritedWidgetOfExactType<_WorkspaceLayoutScope>()?.openSidebar();
}

/// Кнопка меню в шапке страницы на узком экране: открывает панель с чатами, хостами и настройками.
class WorkspaceMenuButton extends StatelessWidget {
  const WorkspaceMenuButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: AppLocalizations.of(context).sidebarExpand,
    icon: const Icon(Icons.menu),
    onPressed: () => context.openWorkspaceSidebar(),
  );
}

/// Кнопка слева в шапке страницы оболочки на узком экране. Обычно это меню, а если страница открыта поверх
/// оболочки (онбординг открывает хосты так) — «назад» к экрану, из которого её открыли.
/// На средней и широкой раскладке кнопку не ставят: панель видна или открывается кнопкой в полосе иконок.
class WorkspaceLeadingButton extends StatelessWidget {
  const WorkspaceLeadingButton({super.key});

  @override
  Widget build(BuildContext context) {
    final root = context.router.root;
    // Смотрим только на корневой стек: вкладки оболочки сами по себе не «назад».
    if (!root.canPop(ignoreChildRoutes: true)) {
      return const WorkspaceMenuButton();
    }
    return BackButton(onPressed: () => unawaited(root.maybePop()));
  }
}

/// Переход без анимации. В широком режиме выбор чата меняет правую часть сразу, без наплыва.
class _InstantTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

const _instantTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _InstantTransitionsBuilder(),
    TargetPlatform.iOS: _InstantTransitionsBuilder(),
    TargetPlatform.linux: _InstantTransitionsBuilder(),
    TargetPlatform.macOS: _InstantTransitionsBuilder(),
    TargetPlatform.windows: _InstantTransitionsBuilder(),
    TargetPlatform.fuchsia: _InstantTransitionsBuilder(),
  },
);

/// Оболочка рабочей области. Раскладка выбирается по ширине окна, а [child] — содержимое вкладок с вложенными
/// маршрутами — всегда стоит на одном месте в дереве. Поэтому при изменении размера окна стек маршрутов и открытый
/// чат сохраняются: меняется только то, что вокруг них.
class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({required this.child, super.key});

  final Widget child;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  var _collapsed = false;
  var _resizing = false;
  ThemeData? _baseTheme;
  ThemeData? _instantTheme;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  void _beginResize() => setState(() => _resizing = true);

  void _endResize() => setState(() => _resizing = false);

  void _openSidebar() => _scaffoldKey.currentState?.openDrawer();

  /// Тема без анимации переходов для широкого режима. Пересоздаётся только при смене самой темы приложения.
  ThemeData _instant(ThemeData base) {
    if (!identical(base, _baseTheme)) {
      _baseTheme = base;
      _instantTheme = base.copyWith(pageTransitionsTheme: _instantTransitions);
    }
    return _instantTheme ?? base;
  }

  @override
  Widget build(BuildContext context) {
    final tabs = AutoTabsRouter.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = WorkspaceLayout.fromWidth(constraints.maxWidth);
        return _WorkspaceLayoutScope(
          layout: layout,
          openSidebar: _openSidebar,
          child: ListenableBuilder(
            // Любой переход в стеках и смена вкладки перестраивают оболочку: выделение в панели берётся из маршрута.
            listenable: tabs.root,
            builder: (context, _) => _scaffold(context, tabs, layout),
          ),
        );
      },
    );
  }

  Widget _scaffold(
    BuildContext context,
    TabsRouter tabs,
    WorkspaceLayout layout,
  ) {
    final sidebarWidth = context.select<SidebarCubit, double>(
      (cubit) => cubit.state.width,
    );
    final activeTab = WorkspaceTab.values[tabs.activeIndex];
    final selectedChatId = selectedChatIdOf(tabs);
    final theme = Theme.of(context);
    return Scaffold(
      key: _scaffoldKey,
      drawer: layout == .wide
          ? null
          : Builder(
              builder: (drawerContext) => Drawer(
                width: sidebarWidth,
                child: SafeArea(
                  child: _ShellSidebar(
                    activeTab: activeTab,
                    selectedChatId: selectedChatId,
                    onCollapse: () => Scaffold.of(drawerContext).closeDrawer(),
                    onAction: () => Scaffold.of(drawerContext).closeDrawer(),
                  ),
                ),
              ),
            ),
      body: Row(
        children: [
          AnimatedContainer(
            // Перетаскивание не анимируем: иначе панель отстаёт от курсора.
            duration: _resizing ? Duration.zero : AppDurations.normal,
            curve: Curves.easeOutCubic,
            width: _slotWidth(layout, sidebarWidth),
            child: ClipRect(
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
                maxWidth: double.infinity,
                child: AnimatedSwitcher(
                  duration: AppDurations.fast,
                  child: _SidebarSlot(
                    key: ValueKey((layout, _collapsed)),
                    layout: layout,
                    collapsed: _collapsed,
                    sidebarWidth: sidebarWidth,
                    activeTab: activeTab,
                    selectedChatId: selectedChatId,
                    onToggle: _toggle,
                    onOpenSidebar: _openSidebar,
                  ),
                ),
              ),
            ),
          ),
          // Три ребёнка Row при любой раскладке: иначе при смене ширины содержимое переехало бы в другой слот
          // и пересоздалось бы вместе с вложенным навигатором.
          switch (layout) {
            .wide => SidebarResizeHandle(
              enabled: !_collapsed,
              onDragStart: _beginResize,
              onDragEnd: _endResize,
            ),
            .medium => const VerticalDivider(width: 1),
            .compact => const SizedBox.shrink(),
          },
          Expanded(
            child: Theme(
              data: layout == .wide ? _instant(theme) : theme,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }

  double _slotWidth(WorkspaceLayout layout, double sidebarWidth) =>
      switch (layout) {
        .wide => _collapsed ? AppLayout.railWidth : sidebarWidth,
        .medium => AppLayout.railWidth,
        .compact => 0.0,
      };
}

/// Содержимое боковой колонки: полная панель, полоса иконок или ничего (компактный режим).
/// Сам виджет один и тот же, меняется его ключ в [AnimatedSwitcher], поэтому смена раскладки анимируется.
class _SidebarSlot extends StatelessWidget {
  const _SidebarSlot({
    required this.layout,
    required this.collapsed,
    required this.sidebarWidth,
    required this.activeTab,
    required this.selectedChatId,
    required this.onToggle,
    required this.onOpenSidebar,
    super.key,
  });

  final WorkspaceLayout layout;
  final bool collapsed;
  final double sidebarWidth;
  final WorkspaceTab activeTab;
  final String? selectedChatId;

  /// Свернуть или развернуть панель в широком режиме.
  final VoidCallback onToggle;

  /// Открыть панель как drawer в среднем режиме.
  final VoidCallback onOpenSidebar;

  @override
  Widget build(BuildContext context) => switch (layout) {
    .compact => const SizedBox.shrink(),
    .medium => _RailSlot(activeTab: activeTab, onExpand: onOpenSidebar),
    .wide when collapsed => _RailSlot(activeTab: activeTab, onExpand: onToggle),
    .wide => SizedBox(
      width: sidebarWidth,
      child: _ShellSidebar(
        activeTab: activeTab,
        selectedChatId: selectedChatId,
        onCollapse: onToggle,
      ),
    ),
  };
}

/// Полоса иконок. Стоит внутри Scaffold, поэтому [onExpand] открывает drawer этого Scaffold.
class _RailSlot extends StatelessWidget {
  const _RailSlot({required this.activeTab, required this.onExpand});

  final WorkspaceTab activeTab;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => WorkspaceRail(
    activeTab: activeTab,
    onExpand: onExpand,
    onNewChat: () => openNewChat(context),
    onOpenTab: (tab) => showWorkspaceTab(context, tab),
  );
}

/// Панель с чатами внутри оболочки. В drawer после каждого действия он закрывается через [onAction].
class _ShellSidebar extends StatelessWidget {
  const _ShellSidebar({
    required this.activeTab,
    required this.selectedChatId,
    required this.onCollapse,
    this.onAction,
  });

  final WorkspaceTab activeTab;
  final String? selectedChatId;
  final VoidCallback onCollapse;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => WorkspaceSidebar(
    activeTab: activeTab,
    selectedChatId: selectedChatId,
    onCollapse: onCollapse,
    onOpenChat: (chatId) => _openChat(context, chatId),
    onNewChat: () => _newChat(context),
    onOpenTab: (tab) => _openTab(context, tab),
  );

  void _openChat(BuildContext context, String chatId) {
    openChat(context, chatId);
    onAction?.call();
  }

  void _newChat(BuildContext context) {
    openNewChat(context);
    onAction?.call();
  }

  void _openTab(BuildContext context, WorkspaceTab tab) {
    showWorkspaceTab(context, tab);
    onAction?.call();
  }
}
