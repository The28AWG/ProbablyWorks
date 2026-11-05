/// Git для виртуального хоста.
///
/// Команды читают и пишут только виртуальную файловую систему.
/// Сеть — HTTP через [GitHttp]. SSH и диск машины сюда не входят.
library;

export 'package:virtual_git/src/git_applet.dart';
export 'package:virtual_git/src/git_apply.dart';
export 'package:virtual_git/src/git_branch.dart';
export 'package:virtual_git/src/git_branch_tracking.dart';
export 'package:virtual_git/src/git_checkout.dart';
export 'package:virtual_git/src/git_clone.dart';
export 'package:virtual_git/src/git_commit.dart';
export 'package:virtual_git/src/git_commit_codec.dart';
export 'package:virtual_git/src/git_conflict.dart';
export 'package:virtual_git/src/git_delta.dart';
export 'package:virtual_git/src/git_delta_codec.dart';
export 'package:virtual_git/src/git_diff.dart';
export 'package:virtual_git/src/git_diff_codec.dart';
export 'package:virtual_git/src/git_fetch.dart';
export 'package:virtual_git/src/git_hash_algorithm.dart';
export 'package:virtual_git/src/git_host_io.dart'
    show attachGitHttp, bindGitIo, clearGitIo, gitFs, gitHttp;
export 'package:virtual_git/src/git_http.dart';
export 'package:virtual_git/src/git_ignore.dart';
export 'package:virtual_git/src/git_index.dart';
export 'package:virtual_git/src/git_index_codec.dart';
export 'package:virtual_git/src/git_log.dart';
export 'package:virtual_git/src/git_loose_object_codec.dart';
export 'package:virtual_git/src/git_ls_files.dart';
export 'package:virtual_git/src/git_merge.dart';
export 'package:virtual_git/src/git_object.dart';
export 'package:virtual_git/src/git_object_id.dart';
export 'package:virtual_git/src/git_object_type.dart';
export 'package:virtual_git/src/git_pack.dart';
export 'package:virtual_git/src/git_pack_codec.dart';
export 'package:virtual_git/src/git_pack_index.dart';
export 'package:virtual_git/src/git_pack_index_codec.dart';
export 'package:virtual_git/src/git_pack_resolver.dart';
export 'package:virtual_git/src/git_pull.dart';
export 'package:virtual_git/src/git_push.dart';
export 'package:virtual_git/src/git_recovery.dart';
export 'package:virtual_git/src/git_reference.dart';
export 'package:virtual_git/src/git_reference_info.dart';
export 'package:virtual_git/src/git_reflog.dart';
export 'package:virtual_git/src/git_reflog_codec.dart';
export 'package:virtual_git/src/git_refspec.dart';
export 'package:virtual_git/src/git_remote.dart';
export 'package:virtual_git/src/git_remote_reference.dart';
export 'package:virtual_git/src/git_repository.dart';
export 'package:virtual_git/src/git_reset.dart';
export 'package:virtual_git/src/git_restore.dart';
export 'package:virtual_git/src/git_stash.dart';
export 'package:virtual_git/src/git_status.dart';
export 'package:virtual_git/src/git_tag.dart';
export 'package:virtual_git/src/git_tag_codec.dart';
export 'package:virtual_git/src/git_tree.dart';
export 'package:virtual_git/src/git_tree_codec.dart';
export 'package:virtual_git/src/git_worktree.dart';
export 'package:virtual_git/src/git_write_tree.dart';
