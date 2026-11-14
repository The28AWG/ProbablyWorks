import 'package:pw_agent/providers/ai/llm_port.dart';

/// Id модели для показа: префикс провайдера нужен только для маршрутизации
/// и в интерфейсе не показывается.
String modelIdForDisplay(
  String id, {
  List<LlmProviderDescriptor> providers = const [],
}) {
  final descriptor = providerDescriptorOf(id, providers);
  return descriptor == null ? id : descriptor.localModelId(id);
}

/// Время последнего обновления каталога для подписи, например `02.11 20:54` (локальное время).
String formatModelSyncTime(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)} '
      '${two(local.hour)}:${two(local.minute)}';
}
