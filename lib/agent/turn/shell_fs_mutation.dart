import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/command_risk.dart';

/// Команда shell могла изменить файлы в обход write_file/edit_file.
///
/// Точного статического анализа нет: помечаем ход, если команда не запрещена
/// и не классифицирована как однозначно читающая (auto + read-only).
bool shellMayMutateFilesystem(CommandClassifier classifier, String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) return false;
  final verdict = classifier.classify(trimmed);
  if (verdict.risk == CommandRisk.deny) return false;
  if (verdict.risk == CommandRisk.auto &&
      verdict.reason == 'read-only command') {
    return false;
  }
  return true;
}
