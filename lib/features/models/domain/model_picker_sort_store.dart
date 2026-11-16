import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';

/// Хранит сортировку, выбранную в диалоге выбора модели.
///
/// Сортировка — клиентская настройка, а не свойство чата: пользователь
/// выбирает её один раз, и следующий диалог открывается с тем же порядком.
/// Список моделей большой, и повторный выбор порядка на каждом открытии был бы
/// лишним действием. Без [ClientSettings] значение живёт только в памяти.
class ModelPickerSortStore {
  ModelPickerSortStore([this._settings]);

  final ClientSettings? _settings;
  ModelSort? _cached;

  /// Сохранённая сортировка. Неизвестное или отсутствующее значение — [ModelSort.provider].
  Future<ModelSort> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    final raw = await _settings?.read(ClientSettingsKeys.modelSort);
    final sort = ModelSort.values.asNameMap()[raw] ?? ModelSort.provider;
    _cached = sort;
    return sort;
  }

  /// Запоминает выбор. Ошибка записи не ловится: диалог не должен падать
  /// из-за настройки, поэтому вызывающий код пишет без ожидания результата.
  Future<void> save(ModelSort sort) async {
    _cached = sort;
    await _settings?.write(ClientSettingsKeys.modelSort, sort.name);
  }
}
