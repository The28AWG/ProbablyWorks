import 'package:app_ui/app_ui.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/core/data/settings_repository.dart';

class SidebarState extends Equatable {
  const SidebarState({this.width = AppLayout.sidebarWidth});

  /// Ширина развёрнутой боковой панели в широком режиме и в drawer.
  final double width;

  @override
  List<Object?> get props => [width];
}

/// Ширина, прочитанная до первого кадра (см. bootstrap). Панель стартует с неё сразу,
/// поэтому не переезжает после запуска.
class SidebarStartupWidth {
  const SidebarStartupWidth(this.value);

  final double value;
}

/// Ширина боковой панели: сохраняется после изменения и восстанавливается при следующем запуске.
class SidebarCubit extends Cubit<SidebarState> {
  SidebarCubit(this._settings, double initialWidth)
    : super(SidebarState(width: clampWidth(initialWidth)));

  final SettingsRepository _settings;

  static double clampWidth(double width) => width
      .clamp(AppLayout.sidebarMinWidth, AppLayout.sidebarMaxWidth)
      .toDouble();

  /// Читает сохранённую ширину. Вызывается один раз при старте, до показа интерфейса.
  static Future<double> loadWidth(SettingsRepository settings) async {
    final stored = double.tryParse(
      await settings.read(SettingsRepository.keySidebarWidth) ?? '',
    );
    return stored == null ? AppLayout.sidebarWidth : clampWidth(stored);
  }

  /// Ширина по положению курсора при перетаскивании: только состояние, без записи в БД.
  void resizeTo(double width) => emit(SidebarState(width: clampWidth(width)));

  /// Шаг с клавиатуры: относительное изменение, тоже в пределах границ.
  void resizeBy(double delta) => resizeTo(state.width + delta);

  /// Фиксирует ширину после жеста или шага с клавиатуры, чтобы она пережила перезапуск.
  Future<void> commit() => _settings.write(
    SettingsRepository.keySidebarWidth,
    state.width.round().toString(),
  );
}
