/// Имена секретов плагина «Веб».
///
/// Значение хранится в `SecretStore` под ключом
/// `plugin.web.secret.<name>`; в настройках плагина лежит только ссылка
/// `${secret:plugin.web.secret.searchKey}`.
abstract final class WebSecrets {
  const WebSecrets._();

  /// Ключ поискового провайдера (Brave, Tavily).
  static const searchKey = 'searchKey';

  /// Ссылка для заголовка `X-Subscription-Token` / `Authorization`.
  static const searchKeyRef = r'${secret:plugin.web.secret.searchKey}';
}
