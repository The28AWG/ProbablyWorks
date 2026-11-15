/// Дескриптор провайдера локальных моделей.
///
/// Провайдер — тонкая вьюха над средой выполнения: файлами, параметрами и
/// очередью владеет `LocalModelsService`. Поэтому у провайдера нет ни адреса
/// сервера, ни ключа, а модели приходят из установленных файлов.
library;

import 'package:pw_agent/providers/ai/llm_port.dart';

/// Стабильный id провайдера в настройках, API и секретах.
const llamadartProviderId = 'llamadart';

/// Префикс моделей провайдера в общем каталоге.
const llamadartModelPrefix = 'llamadart:';

/// Описание провайдера для каталога, настроек и интерфейса.
const llamadartDescriptor = LlmProviderDescriptor(
  id: llamadartProviderId,
  label: 'llamadart',
  modelPrefix: llamadartModelPrefix,
  supportsApiKey: false,
  supportsBaseUrl: false,
  localModels: true,
);
