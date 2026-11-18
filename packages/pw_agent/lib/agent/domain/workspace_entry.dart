import 'package:equatable/equatable.dart';

/// Файл или каталог workspace, который можно упомянуть в сообщении.
class WorkspaceEntry extends Equatable {
  const WorkspaceEntry({required this.path, required this.isDirectory});

  factory WorkspaceEntry.fromJson(Map<String, dynamic> json) => WorkspaceEntry(
    path: '${json['path'] ?? ''}',
    isDirectory: json['isDirectory'] == true,
  );

  /// Путь относительно workspace, без ведущего `/` и хвостового разделителя.
  final String path;

  final bool isDirectory;

  Map<String, dynamic> toJson() => {'path': path, 'isDirectory': isDirectory};

  @override
  List<Object?> get props => [path, isDirectory];
}
