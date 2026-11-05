import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Заполняет ФС виртуального Host стартовым содержимым: домашним каталогом. Без него первая же
/// команда `cd ~` сломалась бы, а агент не умеет создавать корень сам. `/tmp` сюда не входит:
/// это память процесса, каталог появляется при обращении к слою.
///
/// Функция идемпотентна: существующий домашний каталог не трогает, поэтому её безопасно вызывать
/// при каждом сохранении хоста. Файлов пользователя она не создаёт и ничего не удаляет.
Future<void> seedVirtualHost(VirtualFs fs, VirtualProfile profile) =>
    fs.mkdir(profile.home, recursive: true);
