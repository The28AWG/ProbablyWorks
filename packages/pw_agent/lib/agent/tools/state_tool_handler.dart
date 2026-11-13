import 'dart:convert';

import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/skills/builtin_skills.dart';
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/tools/tool_args.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_types.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:uuid/uuid.dart';

/// Инструменты состояния задачи: цель, план, закреплённые факты, ревизии,
/// поиск по истории и skills. Не решает policy и не запускает процессы —
/// это остаётся [ToolExecutor].
class StateToolHandler {
  StateToolHandler(this._chats, this._state, this._projects, this._workspace);

  final ChatRepository _chats;
  final SessionStateService _state;
  final ProjectRepository _projects;
  final WorkspaceContextLoader _workspace;

  static const _uuid = Uuid();

  /// Выполняет инструмент состояния задачи. Возвращает текст для модели,
  /// ошибки аргументов остаются исключениями и обрабатываются ToolExecutor.
  Future<ToolResult> call(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final chat = await _chats.chat(ctx.chat.id) ?? ctx.chat;
    switch (call.name) {
      case ToolNames.setGoal:
        final goal = toolStringArg(args, 'goal');
        await _state.mutate(chat, (rev) => rev.goal = goal);
        return const ToolResult('goal saved');
      case ToolNames.updatePlan:
        final items = [
          for (final item in (args['items'] as List? ?? const []))
            PlanItem(
              id: (item as Map)['id'] as String,
              text: item['text'] as String,
              status: PlanItemStatus.values.byName(
                item['status'] as String? ?? 'pending',
              ),
            ),
        ];
        await _state.mutate(chat, (rev) {
          rev
            ..plan = items
            ..taskStatus = items.isEmpty ? TaskStatus.idle : TaskStatus.active;
        });
        return ToolResult('plan updated: ${items.length} items');
      case ToolNames.pinFact:
        final fact = PinnedFact(
          id: charPrefix(_uuid.v4(), 8),
          text: toolStringArg(args, 'text'),
          createdAt: DateTime.now(),
        );
        await _state.mutate(
          chat,
          (rev) => rev.pinnedFacts = [...rev.pinnedFacts, fact],
        );
        return ToolResult('pinned fact ${fact.id}');
      case ToolNames.unpinFact:
        final id = toolStringArg(args, 'id');
        await _state.mutate(
          chat,
          (rev) =>
              rev.pinnedFacts = [...rev.pinnedFacts]
                ..removeWhere((f) => f.id == id),
        );
        return ToolResult('unpinned fact $id');
      case ToolNames.listStateRevisions:
        final lines = await _state.sealedIndex(chat.id);
        return ToolResult(
          lines.isEmpty ? 'no earlier revisions' : lines.join('\n'),
        );
      case ToolNames.getStateRevision:
        final revision = await _chats.revision(toolStringArg(args, 'id'));
        if (revision == null ||
            revision.chatId != chat.id ||
            !revision.sealed) {
          return const ToolResult(
            'sealed revision not found in this chat',
            isError: true,
          );
        }
        return ToolResult(
          jsonEncode({
            'id': revision.id,
            'parentId': revision.parentId,
            ...revision.stateToJson(),
          }),
        );
      case ToolNames.chatHistorySearch:
        final query = toolStringArg(args, 'query');
        final scope = toolStringArg(args, 'scope');
        if (scope.isEmpty || scope == 'chat') {
          final found = await _chats.searchMessages(chat.id, query);
          if (found.isEmpty) return const ToolResult('no matches');
          return ToolResult(
            [
              for (final m in found)
                '#${m.seq} ${m.role.name}: ${previewToolText(m.text, max: 300)}',
            ].join('\n'),
          );
        }
        if (scope != 'project' && scope != 'all') {
          return const ToolResult(
            'scope must be chat, project or all',
            isError: true,
          );
        }
        final projectId = scope == 'project' ? ctx.project?.id : null;
        if (scope == 'project' && projectId == null) {
          return const ToolResult(
            'this chat has no project; project search is unavailable',
            isError: true,
          );
        }
        final found = await _chats.searchMessagesAll(
          query,
          projectId: projectId,
        );
        if (found.isEmpty) return const ToolResult('no matches');
        return ToolResult(
          [
            for (final hit in found)
              '${hit.chatTitle} #${hit.message.seq} ${hit.message.role.name}: ${previewToolText(hit.message.text, max: 300)}',
          ].join('\n'),
        );
      case ToolNames.listSkills:
        final trusted = ctx.project == null
            ? const <String>{}
            : await _projects.trustedSkillNames(ctx.project!.id);
        final snapshot = await _workspace.load(
          chat,
          ctx.runtime,
          project: ctx.project,
          trustedSkills: trusted,
        );
        final skills = BuiltinSkills.catalog(
          snapshot.needsTrust ? const [] : snapshot.skills,
        );
        final note = snapshot.needsTrust
            ? '\nworkspace skills are unavailable until the workspace is trusted'
            : '';
        return ToolResult(
          [for (final s in skills) '${s.name}: ${s.description}'].join('\n') +
              note,
        );
      case ToolNames.loadSkill:
        final name = toolStringArg(args, 'name');
        final builtin = BuiltinSkills.byName(name);
        if (builtin != null) return ToolResult(builtin.body);
        final trusted = ctx.project == null
            ? const <String>{}
            : await _projects.trustedSkillNames(ctx.project!.id);
        final snapshot = await _workspace.load(
          chat,
          ctx.runtime,
          project: ctx.project,
          trustedSkills: trusted,
        );
        final skill = snapshot.skills.where((s) => s.name == name).firstOrNull;
        if (skill == null) {
          return ToolResult('skill not found: $name', isError: true);
        }
        final body = await _workspace.loadSkillBody(ctx.runtime, skill);
        return body == null
            ? ToolResult('cannot read skill $name', isError: true)
            : ToolResult(body);
    }
    return ToolResult('unknown state tool: ${call.name}', isError: true);
  }
}
