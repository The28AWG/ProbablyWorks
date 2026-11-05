import 'package:probably_works/core/domain/host.dart';
import 'package:virtual_host/virtual_host.dart';

/// Имя хоста, если из названия не получилось ни одного допустимого символа.
const _fallbackHostname = 'probably';

/// Максимальная длина имени хоста по RFC 1123: метка DNS не длиннее 63 символов.
const _maxHostnameLength = 63;

/// Профиль виртуального Host из его записи. Пользователь и домашний каталог фиксированы: у песочницы
/// один агент, а имя хоста берётся из названия, которое пользователь задал сам. [VirtualProfile.bootedAt]
/// берётся из даты создания записи Host: `uptime` считает время от неё, поэтому не сбрасывается при
/// перезапуске приложения. [Host.environment] копируется в профиль: оболочка экспортирует карту и не даёт
/// ей затереть `PATH`, `HOME` и остальные встроенные имена. `host_info` эту карту не печатает.
VirtualProfile virtualProfileFor(Host host) => VirtualProfile(
  hostname: hostnameFor(host.name),
  bootedAt: host.createdAt.millisecondsSinceEpoch ~/ 1000,
  environment: host.environment,
);

/// Превращает произвольное название в имя хоста для `hostname` и `uname`: строчные латиница, цифры и
/// дефисы, без дефисов по краям, не длиннее [_maxHostnameLength]. Пустой результат заменяем на
/// [_fallbackHostname], иначе `uname` выдал бы пустое имя.
String hostnameFor(String name) {
  final cleaned = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final limited = String.fromCharCodes(
    cleaned.codeUnits.take(_maxHostnameLength),
  ).replaceAll(RegExp(r'-+$'), '');
  return limited.isEmpty ? _fallbackHostname : limited;
}
