import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Права `/tmp` как у реального Linux: `rwxrwxrwt`, то есть 1777 в восьмеричной записи. Sticky-бит (1000)
/// не даёт удалять чужие файлы; Dart не знает восьмеричных литералов, поэтому значение записано числом.
const _sharedTmpMode = 1023;

/// Заполняет ФС виртуального Host стартовым содержимым: домашний каталог и `/tmp`. Без них первая же
/// команда `cd ~` или запись во временный файл сломалась бы, а агент не умеет создавать корень сам.
///
/// Функция идемпотентна: существующие каталоги не трогает, поэтому её безопасно вызывать при каждом
/// сохранении хоста. Файлов пользователя она не создаёт и ничего не удаляет.
Future<void> seedVirtualHost(VirtualFs fs, VirtualProfile profile) async {
  await fs.mkdir(profile.home, recursive: true);
  await fs.mkdir('/tmp', recursive: true);
  await fs.chmod('/tmp', _sharedTmpMode);
}
