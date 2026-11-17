/// Ядро плагина «Веб»: поиск, чтение страниц и сбор данных.
///
/// Пакет не импортирует Flutter: те же инструменты работают в GUI и в
/// headless-демоне. Сеть доступна только через [PluginHost], поэтому запросы
/// проходят общую проверку приложения.
library;

export 'src/fetch/page_document.dart' show PageDocument, PageOutlineEntry;
export 'src/page_store.dart' show PageSnapshot, WebPageStore;
export 'src/web_config.dart';
export 'src/web_plugin.dart' show WebPlugin;
export 'src/web_secrets.dart';
