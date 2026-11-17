import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:plugin_web/l10n/generated/web_localizations.dart';
import 'package:plugin_web_core/plugin_web_core.dart';

/// Представление плагина «Веб» в настройках.
final class WebPluginUi implements PluginUi {
  const WebPluginUi();

  @override
  String get pluginId => 'web';

  @override
  LocalizationsDelegate<dynamic> get localizations => WebLocalizations.delegate;

  @override
  String titleOf(BuildContext context) =>
      WebLocalizations.of(context).pluginTitle;

  @override
  String descriptionOf(BuildContext context) =>
      WebLocalizations.of(context).pluginDescription;

  @override
  Widget? buildSettings(BuildContext context, PluginSettings settings) =>
      WebSettingsPage(settings: settings);
}

/// Экран настроек плагина «Веб».
class WebSettingsPage extends StatefulWidget {
  const WebSettingsPage({required this.settings, super.key});

  final PluginSettings settings;

  @override
  State<WebSettingsPage> createState() => _WebSettingsPageState();
}

class _WebSettingsPageState extends State<WebSettingsPage> {
  late final _endpoint = TextEditingController();
  late final _key = TextEditingController();
  late final _maxResults = TextEditingController();
  late final _language = TextEditingController();
  late final _maxChars = TextEditingController();
  late final _maxBytes = TextEditingController();
  late final _timeout = TextEditingController();
  late final _userAgent = TextEditingController();
  late final _cacheTtl = TextEditingController();
  late final _allow = TextEditingController();
  late final _deny = TextEditingController();

  var _provider = WebSearchProvider.brave;
  var _safeSearch = true;
  var _respectRobots = true;
  var _hasKey = false;
  var _loading = true;
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _key.dispose();
    _maxResults.dispose();
    _language.dispose();
    _maxChars.dispose();
    _maxBytes.dispose();
    _timeout.dispose();
    _userAgent.dispose();
    _cacheTtl.dispose();
    _allow.dispose();
    _deny.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw = await widget.settings.read();
      final config = WebConfig.fromJson(raw);
      final hasKey = await widget.settings.hasSecret(WebSecrets.searchKey);
      if (!mounted) return;
      setState(() {
        _provider = config.search.provider;
        _endpoint.text = config.search.endpoint;
        _maxResults.text = '${config.search.maxResults}';
        _language.text = config.search.language;
        _safeSearch = config.search.safeSearch;
        _maxChars.text = '${config.fetch.maxChars}';
        _maxBytes.text = '${config.fetch.maxBytes}';
        _timeout.text = '${config.fetch.timeoutSeconds}';
        _userAgent.text = config.fetch.userAgent;
        _respectRobots = config.fetch.respectRobots;
        _cacheTtl.text = '${config.fetch.cacheTtlMinutes}';
        _allow.text = config.domains.allow.join('\n');
        _deny.text = config.domains.deny.join('\n');
        _hasKey = hasKey;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = WebLocalizations.of(context);
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(child: Text(l10n.loading)),
      );
    }
    if (_error case final error?) {
      return AppBanner(
        message: '${l10n.errorTitle}: $error',
        tone: AppTone.danger,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSection(
          title: l10n.searchSection,
          description: l10n.searchSectionHint,
          children: [
            AppChoiceGroup<WebSearchProvider>(
              selected: _provider,
              onChanged: _changeProvider,
              options: [
                AppChoiceOption(
                  value: WebSearchProvider.brave,
                  title: l10n.providerBrave,
                  subtitle: l10n.providerBraveHint,
                  icon: const Icon(Icons.travel_explore_outlined),
                ),
                AppChoiceOption(
                  value: WebSearchProvider.tavily,
                  title: l10n.providerTavily,
                  subtitle: l10n.providerTavilyHint,
                  icon: const Icon(Icons.manage_search_outlined),
                ),
                AppChoiceOption(
                  value: WebSearchProvider.searxng,
                  title: l10n.providerSearxng,
                  subtitle: l10n.providerSearxngHint,
                  icon: const Icon(Icons.dns_outlined),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _endpoint,
              label: l10n.endpoint,
              hint: l10n.endpointHint,
              mono: true,
              keyboardType: TextInputType.url,
            ),
            if (_provider != WebSearchProvider.searxng) ...[
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _key,
                label: l10n.apiKey,
                hint: _hasKey ? l10n.apiKeySaved : l10n.apiKeyHint,
                obscure: true,
                mono: true,
              ),
              if (_hasKey) ...[
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _saving ? null : _removeKey,
                    child: Text(l10n.apiKeyRemove),
                  ),
                ),
              ],
            ],
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _maxResults,
              label: l10n.maxResults,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: AppSpacing.md),
            _SwitchRow(
              title: l10n.safeSearch,
              value: _safeSearch,
              onChanged: (value) => setState(() => _safeSearch = value),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _language,
              label: l10n.language,
              hint: l10n.languageHint,
              mono: true,
            ),
            if (!_hasKey && _provider != WebSearchProvider.searxng)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  l10n.searchNotConfigured,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        AppSection(
          title: l10n.pagesSection,
          description: l10n.pagesSectionHint,
          children: [
            AppTextField(
              controller: _maxChars,
              label: l10n.maxChars,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _maxBytes,
              label: l10n.maxBytes,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _timeout,
              label: l10n.timeoutSeconds,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _userAgent,
              label: l10n.userAgent,
              hint: l10n.userAgentHint,
              mono: true,
            ),
            const SizedBox(height: AppSpacing.md),
            _SwitchRow(
              title: l10n.respectRobots,
              value: _respectRobots,
              onChanged: (value) => setState(() => _respectRobots = value),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _cacheTtl,
              label: l10n.cacheTtl,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(l10n.cacheNote, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        AppSection(
          title: l10n.domainsSection,
          description: l10n.domainsSectionHint,
          children: [
            AppTextField(
              controller: _allow,
              label: l10n.allowedDomains,
              hint: l10n.allowedDomainsHint,
              minLines: 2,
              maxLines: 4,
              mono: true,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _deny,
              label: l10n.deniedDomains,
              hint: l10n.deniedDomainsHint,
              minLines: 2,
              maxLines: 4,
              mono: true,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : () => _save(context),
            child: Text(l10n.save),
          ),
        ),
      ],
    );
  }

  void _changeProvider(WebSearchProvider provider) {
    final oldDefault = WebSearchConfig.defaultEndpoint(_provider);
    final newDefault = WebSearchConfig.defaultEndpoint(provider);
    final current = _endpoint.text.trim();
    setState(() {
      _provider = provider;
      if (current.isEmpty || current == oldDefault) {
        _endpoint.text = newDefault;
      }
    });
  }

  Future<void> _removeKey() async {
    final l10n = WebLocalizations.of(context);
    setState(() => _saving = true);
    try {
      await widget.settings.writeSecret(WebSecrets.searchKey, null);
      if (!mounted) return;
      setState(() {
        _hasKey = false;
        _key.clear();
        _saving = false;
      });
      AppSnackBar.show(context, l10n.apiKeyRemoved);
    } on Object catch (error) {
      if (!mounted || !context.mounted) return;
      setState(() => _saving = false);
      AppSnackBar.show(context, l10n.saveFailed('$error'));
    }
  }

  Future<void> _save(BuildContext context) async {
    final l10n = WebLocalizations.of(context);
    final maxResults = int.tryParse(_maxResults.text.trim());
    final maxChars = int.tryParse(_maxChars.text.trim());
    final maxBytes = int.tryParse(_maxBytes.text.trim());
    final timeout = int.tryParse(_timeout.text.trim());
    final cacheTtl = int.tryParse(_cacheTtl.text.trim());
    final endpoint = _endpoint.text.trim();
    if (maxResults == null ||
        maxResults < 1 ||
        maxResults > 10 ||
        maxChars == null ||
        maxChars < 1000 ||
        maxChars > 30000 ||
        maxBytes == null ||
        maxBytes < 65536 ||
        maxBytes > 8388608 ||
        timeout == null ||
        timeout < 1 ||
        timeout > 60 ||
        cacheTtl == null ||
        cacheTtl < 0 ||
        cacheTtl > 1440) {
      AppSnackBar.show(context, l10n.invalidNumber);
      return;
    }
    if (_provider == WebSearchProvider.searxng && endpoint.isEmpty) {
      AppSnackBar.show(context, l10n.invalidEndpointRequired);
      return;
    }
    if (endpoint.isNotEmpty) {
      final uri = Uri.tryParse(endpoint);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          !uri.hasAuthority) {
        AppSnackBar.show(context, l10n.invalidEndpoint);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final config = WebConfig(
        search: WebSearchConfig(
          provider: _provider,
          endpoint: endpoint,
          maxResults: maxResults,
          safeSearch: _safeSearch,
          language: _language.text.trim(),
        ),
        fetch: WebFetchConfig(
          maxChars: maxChars,
          maxBytes: maxBytes,
          timeoutSeconds: timeout,
          userAgent: _userAgent.text.trim(),
          respectRobots: _respectRobots,
          cacheTtlMinutes: cacheTtl,
        ),
        domains: WebDomainPolicy(
          allow: _domains(_allow.text),
          deny: _domains(_deny.text),
        ),
      );
      await widget.settings.save(config.toJson());
      final key = _key.text.trim();
      if (key.isNotEmpty) {
        await widget.settings.writeSecret(WebSecrets.searchKey, key);
        _key.clear();
      }
      final hasKey = await widget.settings.hasSecret(WebSecrets.searchKey);
      if (!mounted || !context.mounted) return;
      setState(() {
        _hasKey = hasKey;
        _saving = false;
      });
      AppSnackBar.show(context, l10n.saved);
    } on Object catch (error) {
      if (!mounted || !context.mounted) return;
      setState(() => _saving = false);
      AppSnackBar.show(context, l10n.saveFailed('$error'));
    }
  }

  static List<String> _domains(String value) => [
    for (final line in value.split(RegExp(r'[\n,]')))
      if (line.trim().isNotEmpty) line.trim(),
  ];
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title)),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}
