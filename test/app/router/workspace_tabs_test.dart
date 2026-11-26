import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/pages/workspace_page.dart';
import 'package:pw_agent/agent/api/agent_api.dart';

void main() {
  test('workspace tabs follow the WorkspaceTab order', () {
    final routes = workspaceTabRoutes(AgentStatus.online);

    expect(routes, hasLength(WorkspaceTab.values.length));
    expect(routes[WorkspaceTab.chats.index], isA<ChatsTabRoute>());
    expect(routes[WorkspaceTab.inbox.index], isA<InboxRoute>());
    expect(routes[WorkspaceTab.projects.index], isA<ProjectsTabRoute>());
    expect(routes[WorkspaceTab.hosts.index], isA<HostsRoute>());
    expect(routes[WorkspaceTab.settings.index], isA<SettingsRoute>());
  });
}
