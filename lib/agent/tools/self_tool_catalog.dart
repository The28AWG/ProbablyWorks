import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Инструменты самонастройки приложения. Доступны всегда; правила работы описаны в скилле probablyworks.
/// Гарантии (пароли, ключи хоста, подтверждение keyPath и записи) обеспечивает код, а не текст скилла.
abstract final class SelfToolCatalog {
  const SelfToolCatalog._();

  static const _hostId = {
    'type': 'string',
    'description': 'Host id from host_list',
  };

  static const specs = [
    LlmToolSpec(
      name: ToolNames.hostList,
      description:
          'List ProbablyWorks hosts (not remote commands): id, name, kind, address, port, username, '
          'os, default workspace, notes and the last connection check.',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    LlmToolSpec(
      name: ToolNames.hostAdd,
      description:
          'Add an SSH host. Passwords, passphrases and private keys are never accepted: the user enters them on the Hosts page. '
          'keyPath is a path on the machine running ProbablyWorks, passed exactly as the user wrote it (absolute, ~ or ~/...). '
          'The user is asked to approve it unless the user named it.',
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'address': {'type': 'string', 'description': 'Host name or IP'},
          'port': {'type': 'integer', 'description': 'Default 22'},
          'username': {'type': 'string'},
          'authType': {
            'type': 'string',
            'enum': ['key', 'password'],
          },
          'keyPath': {
            'type': 'string',
            'description': 'Path to a private key file, only for authType key',
          },
          'os': {
            'type': 'string',
            'enum': ['posix', 'macos', 'windows'],
          },
          'defaultWorkspace': {'type': 'string'},
          'notes': {'type': 'string'},
        },
        'required': ['name', 'address'],
      },
    ),
    LlmToolSpec(
      name: ToolNames.hostUpdate,
      description:
          'Rename a host, replace its notes, or change its default workspace. '
          'Notes are replaced as a whole: read them with host_list first. '
          'Address, port, keys and authentication are changed on the Hosts page.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': _hostId,
          'name': {'type': 'string'},
          'notes': {
            'type': 'string',
            'description': 'Empty string clears the notes',
          },
          'defaultWorkspace': {
            'type': 'string',
            'description': 'Empty string clears it',
          },
        },
        'required': ['id'],
      },
    ),
    LlmToolSpec(
      name: ToolNames.hostTest,
      description:
          'Quick connection check of a host: runs host_info and saves the result. '
          'Returns ok with latency, or the failure reason.',
      parameters: {
        'type': 'object',
        'properties': {'id': _hostId},
        'required': ['id'],
      },
    ),
    LlmToolSpec(
      name: ToolNames.hostDiagnose,
      description:
          'Step-by-step connection diagnostics of a host: address and port reachability, '
          'stored credentials and key file, and the connection itself. Never accepts a host key.',
      parameters: {
        'type': 'object',
        'properties': {'id': _hostId},
        'required': ['id'],
      },
    ),
    LlmToolSpec(
      name: ToolNames.settingsRead,
      description:
          'Read the app settings that can be changed: language, defaultModel, titleModel, pinnedModels, '
          'limits (JSON), stepsGroup, stepsThoughts, stepsTools.',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    LlmToolSpec(
      name: ToolNames.settingsUpdate,
      description:
          'Change one app setting by key (see settings_read). Value is text: '
          'language is system, en or ru; models are model ids; pinnedModels is a JSON array of ids; '
          'limits is a JSON object; stepsGroup is yes or no; stepsThoughts is current, all or expanded; '
          'stepsTools is active, all or expanded.',
      parameters: {
        'type': 'object',
        'properties': {
          'key': {
            'type': 'string',
            'enum': [
              'language',
              'defaultModel',
              'titleModel',
              'pinnedModels',
              'limits',
              'stepsGroup',
              'stepsThoughts',
              'stepsTools',
            ],
          },
          'value': {'type': 'string'},
        },
        'required': ['key', 'value'],
      },
    ),
  ];
}
