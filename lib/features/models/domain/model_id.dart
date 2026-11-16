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
