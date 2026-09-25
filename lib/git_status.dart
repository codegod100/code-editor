class GitChange {
  const GitChange({
    required this.path,
    required this.index,
    required this.worktree,
  });

  factory GitChange.fromJson(Map<String, dynamic> json) => GitChange(
        path: json['path'] as String? ?? '',
        index: json['index'] as String? ?? ' ',
        worktree: json['worktree'] as String? ?? ' ',
      );

  final String path;
  final String index;
  final String worktree;

  String get label => index == '?' || worktree == '?'
      ? 'New'
      : index != ' '
          ? 'Staged'
          : 'Modified';
}

enum PullRequestState { none, open, autoMerge, merged, closed }

class GitStatus {
  const GitStatus({
    required this.isRepo,
    required this.files,
    this.branch = '',
    this.ahead = 0,
    this.behind = 0,
    this.hasRemote = false,
    this.hasUpstream = false,
    this.prAvailable = false,
    this.prUrl = '',
    this.prState = PullRequestState.none,
  });

  factory GitStatus.fromJson(Map<String, dynamic> json) => GitStatus(
        isRepo: json['isRepo'] as bool? ?? false,
        branch: json['branch'] as String? ?? '',
        files: (json['files'] as List<dynamic>? ?? const [])
            .map((item) => GitChange.fromJson(item as Map<String, dynamic>))
            .toList(),
        ahead: json['ahead'] as int? ?? 0,
        behind: json['behind'] as int? ?? 0,
        hasRemote: json['hasRemote'] as bool? ?? false,
        hasUpstream: json['hasUpstream'] as bool? ?? false,
        prAvailable: json['prAvailable'] as bool? ?? false,
        prUrl: json['pullRequest']?['url'] as String? ?? '',
        prState: switch (json['pullRequest']?['state']) {
          'MERGED' => PullRequestState.merged,
          'CLOSED' => PullRequestState.closed,
          'OPEN' => json['pullRequest']?['autoMergeEnabled'] == true
              ? PullRequestState.autoMerge
              : PullRequestState.open,
          _ => PullRequestState.none,
        },
      );

  final bool isRepo;
  final String branch;
  final List<GitChange> files;
  final int ahead;
  final int behind;
  final bool hasRemote;
  final bool hasUpstream;
  final bool prAvailable;
  final String prUrl;
  final PullRequestState prState;
  String get prLabel => switch (prState) {
        PullRequestState.none => 'Create PR',
        PullRequestState.open => 'View PR',
        PullRequestState.autoMerge => 'Auto-merge enabled',
        PullRequestState.merged => 'PR merged',
        PullRequestState.closed => 'PR closed',
      };
  int get changedCount => files.length;
}
