import 'package:probably_works/providers/ai/llm_port.dart';

/// Каталог инструментов v1. Имена стабильны: на них завязаны PolicyEngine и ToolExecutor.
abstract final class ToolNames {
  const ToolNames._();
  static const hostInfo = 'host_info';
  static const listDir = 'list_dir';
  static const readFile = 'read_file';
  static const grep = 'grep';
  static const which = 'which';
  static const runCommand = 'run_command';
  static const writeFile = 'write_file';
  static const editFile = 'edit_file';
  static const setGoal = 'set_goal';
  static const updatePlan = 'update_plan';
  static const pinFact = 'pin_fact';
  static const unpinFact = 'unpin_fact';
  static const pinProjectFact = 'pin_project_fact';
  static const unpinProjectFact = 'unpin_project_fact';
  static const listStateRevisions = 'list_state_revisions';
  static const getStateRevision = 'get_state_revision';
  static const chatHistorySearch = 'chat_history_search';
  static const listSkills = 'list_skills';
  static const loadSkill = 'load_skill';
  static const askUser = 'ask_user';
  static const finish = 'finish';

  // Self-инструменты: всегда доступны, см. SelfToolCatalog.
  static const hostList = 'host_list';
  static const hostAdd = 'host_add';
  static const hostUpdate = 'host_update';
  static const hostTest = 'host_test';
  static const hostDiagnose = 'host_diagnose';
  static const settingsRead = 'settings_read';
  static const settingsUpdate = 'settings_update';
}

/// Описания инструментов для модели. Пути — относительно workspace, если не абсолютные.
abstract final class ToolCatalog {
  const ToolCatalog._();
  static const _pathProp = {
    'type': 'string',
    'description': 'File or directory path on the host',
  };

  static final List<LlmToolSpec> specs = [
    const LlmToolSpec(
      name: ToolNames.hostInfo,
      description: 'Describe the host: OS, current user, working directory, shell. On a virtual host the text also lists the bash subset, rejected syntax, and that shell state does not survive run_command.',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    const LlmToolSpec(
      name: ToolNames.listDir,
      description: 'List directory contents.',
      parameters: {
        'type': 'object',
        'properties': {'path': _pathProp},
        'required': ['path'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.readFile,
      description:
          'Read a text file by lines. The result starts with the file size ("[file: N lines, M bytes]"), '
          'then numbered lines, then a footer. If the footer says "[more: continue with offset=K]", '
          'call again with offset=K. A line longer than the per-line limit is cut; the footer then says '
          '"continue with offset=K byte_offset=B" to read the rest of that line. '
          'Use grep first to find line numbers in large files.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': _pathProp,
          'offset': {
            'type': 'integer',
            'description': '1-based line to start from (default 1)',
          },
          'limit': {
            'type': 'integer',
            'description': 'Max lines to return (default 200, max 1000)',
          },
          'byte_offset': {
            'type': 'integer',
            'description': 'Byte position inside line offset, from the footer, to continue a cut line (default 0)',
          },
        },
        'required': ['path'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.grep,
      description:
          'Search for a regular expression recursively under a path (skips .git). '
          'Returns path:line:text, at most 300 lines; a footer says when results are cut.',
      parameters: {
        'type': 'object',
        'properties': {
          'pattern': {'type': 'string'},
          'path': _pathProp,
        },
        'required': ['pattern', 'path'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.which,
      description:
          'Check whether an executable exists on the host and where it is.',
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
        'required': ['name'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.runCommand,
      description:
          'Run a shell command on the host. On a local or SSH host this is a real terminal (PTY): the user sees the output live and can type into it. '
          'On a virtual host there is no PTY. Each call starts a fresh bash subset (functions, if/while/for/select/case, [[ ]], (( )), arrays, traps). '
          'State does not survive the call, background=true is refused, and job control, shopt, exec, coproc and extglob fail before any command. '
          'Read-only commands run automatically; others need user approval. '
          'You cannot type input: a command that waits for input blocks until it times out, so use non-interactive flags (for example -y or --no-pager). '
          'Privilege escalation (sudo, su, doas, pkexec, sudoedit) is forbidden. '
          'Also forbidden: wiping a filesystem root or system directory, writing a block device, and piping a download into a shell. '
          'Set background=true for long-running commands on a local or SSH host; '
          'you will be notified when they finish.',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
          'cwd': {
            'type': 'string',
            'description': 'Working directory (optional)',
          },
          'background': {'type': 'boolean'},
        },
        'required': ['command'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.writeFile,
      description: 'Create or overwrite a text file. The previous version is kept as <path>.pw-bak-<run_id> next to it. Requires approval in Ask mode.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': _pathProp,
          'content': {'type': 'string'},
        },
        'required': ['path', 'content'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.editFile,
      description: 'Replace old_string with new_string in a text file. old_string must be unique unless replace_all is true.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': _pathProp,
          'old_string': {'type': 'string'},
          'new_string': {'type': 'string'},
          'replace_all': {'type': 'boolean'},
        },
        'required': ['path', 'old_string', 'new_string'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.setGoal,
      description: 'Record the current task goal in the session state.',
      parameters: {
        'type': 'object',
        'properties': {
          'goal': {'type': 'string'},
        },
        'required': ['goal'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.updatePlan,
      description: 'Replace the task plan. Each item has id, text and status (pending, doing, done).',
      parameters: {
        'type': 'object',
        'properties': {
          'items': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'text': {'type': 'string'},
                'status': {
                  'type': 'string',
                  'enum': ['pending', 'doing', 'done'],
                },
              },
              'required': ['id', 'text', 'status'],
            },
          },
        },
        'required': ['items'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.pinFact,
      description:
          'Pin a fact that must stay in context for the rest of the task.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.unpinFact,
      description: 'Remove a pinned fact by id.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.pinProjectFact,
      description:
          'Save a long-lived fact for the whole project. Every chat in the project reads it. '
          'The user must confirm it, even in YOLO mode.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.unpinProjectFact,
      description: 'Remove a project fact by id. The user must confirm it, even in YOLO mode.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.listStateRevisions,
      description: 'List earlier session state revisions (id, status, goal).',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    const LlmToolSpec(
      name: ToolNames.getStateRevision,
      description: 'Get the full sealed state (goal, plan, pinned facts) of an earlier revision by id.',
      parameters: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.chatHistorySearch,
      description: 'Full-text search over earlier messages of this chat.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.listSkills,
      description: 'List skills available in the workspace (.agents/skills).',
      parameters: {'type': 'object', 'properties': <String, dynamic>{}},
    ),
    const LlmToolSpec(
      name: ToolNames.loadSkill,
      description: 'Load the full instructions of a skill by name.',
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
        'required': ['name'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.askUser,
      description: 'Ask the user a question and wait for the answer. Use only when you cannot proceed without it.',
      parameters: {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
        },
        'required': ['question'],
      },
    ),
    const LlmToolSpec(
      name: ToolNames.finish,
      description: 'Call when the task is complete. Provide a short summary for the user.',
      parameters: {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string'},
        },
        'required': ['summary'],
      },
    ),
  ];
}
