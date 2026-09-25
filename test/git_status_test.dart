import 'package:cloud_code_editor/git_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status without a PR offers creation', () {
    final status = GitStatus.fromJson({'isRepo': true});
    expect(status.prState, PullRequestState.none);
    expect(status.prLabel, 'Create PR');
    expect(status.prUrl, isEmpty);
  });

  test('refreshed status restores each PR lifecycle state', () {
    for (final entry in [
      ('OPEN', false, PullRequestState.open, 'View PR'),
      ('OPEN', true, PullRequestState.autoMerge, 'Auto-merge enabled'),
      ('MERGED', true, PullRequestState.merged, 'PR merged'),
      ('CLOSED', false, PullRequestState.closed, 'PR closed'),
    ]) {
      final status = GitStatus.fromJson({
        'isRepo': true,
        'hasUpstream': true,
        'pullRequest': {
          'url': 'https://github.com/example/repo/pull/1',
          'state': entry.$1,
          'autoMergeEnabled': entry.$2,
        },
      });
      expect(status.hasUpstream, isTrue);
      expect(status.prState, entry.$3);
      expect(status.prLabel, entry.$4);
      expect(status.prUrl, 'https://github.com/example/repo/pull/1');
    }
  });

  test('switching to a branch without a PR clears submitted state', () {
    var status = GitStatus.fromJson({
      'pullRequest': {
        'url': 'https://github.com/example/repo/pull/1',
        'state': 'OPEN'
      },
    });
    expect(status.prState, PullRequestState.open);
    status = GitStatus.fromJson({'branch': 'new-work', 'pullRequest': null});
    expect(status.prState, PullRequestState.none);
    expect(status.prUrl, isEmpty);
  });
}
