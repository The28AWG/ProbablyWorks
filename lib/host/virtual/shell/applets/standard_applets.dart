import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/applets/archive_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/codec_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/diff_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/fs_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/info_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/link_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/sed_applet.dart';
import 'package:probably_works/host/virtual/shell/applets/system_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/test_applet.dart';
import 'package:probably_works/host/virtual/shell/applets/text_applets.dart';
import 'package:probably_works/host/virtual/shell/applets/text_filter_applets.dart';

/// Стандартный набор апплетов виртуального Host: подмножество GNU coreutils, busybox и bash-встроенных
/// `test`/`[`. Список — единственное место, где апплет становится доступен модели. Имена уникальны:
/// дубликат падает при первом обращении, а не тихо подменяет команду.
final standardApplets = AppletRegistry([
  ...fsApplets,
  ...textApplets,
  ...filterApplets,
  ...infoApplets,
  ...testApplets,
  ...sedApplets,
  ...diffApplets,
  ...codecApplets,
  ...archiveApplets,
  ...linkApplets,
  ...systemApplets,
]);
