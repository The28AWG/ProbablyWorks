import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';
import 'package:probably_works/features/models/domain/model_picker_sort_store.dart';

void main() {
  test('without a saved value the default sort is by provider', () async {
    final store = ModelPickerSortStore(MemoryClientSettings());
    expect(await store.load(), ModelSort.provider);
  });

  test('a saved sort is read back', () async {
    final settings = MemoryClientSettings();
    final store = ModelPickerSortStore(settings);

    await store.save(ModelSort.price);
    expect(settings.values[ClientSettingsKeys.modelSort], 'price');

    // Новый экземпляр читает настройку, а не кэш предыдущего.
    expect(await ModelPickerSortStore(settings).load(), ModelSort.price);
  });

  test('an unknown saved value falls back to the default', () async {
    final settings = MemoryClientSettings({
      ClientSettingsKeys.modelSort: 'unknown',
    });
    expect(await ModelPickerSortStore(settings).load(), ModelSort.provider);
  });

  test('without settings the sort is remembered in memory', () async {
    final store = ModelPickerSortStore();
    await store.save(ModelSort.newest);
    expect(await store.load(), ModelSort.newest);
  });
}
