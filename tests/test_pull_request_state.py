"""Exercise the service helpers without starting the Modal deployment."""
import ast
import asyncio
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock


SOURCE = Path(__file__).resolve().parents[1] / 'deploy.py'


def load_function(name, namespace):
    tree = ast.parse(SOURCE.read_text())
    node = next(n for n in ast.walk(tree)
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == name)
    node.decorator_list = []
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(SOURCE), 'exec'), namespace)
    return namespace[name]


class HTTPError(Exception):
    def __init__(self, status_code, detail):
        super().__init__(detail)
        self.status_code, self.detail = status_code, detail


class PullRequestStateTests(unittest.TestCase):
    def lookup(self, result=None, error=None, branch='feature/rebased-work'):
        runner = Mock(return_value=result, side_effect=error)
        namespace = {
            'Path': Path, 'json': json, 'github_cli_result': runner,
            'subprocess': SimpleNamespace(run=runner, TimeoutExpired=subprocess.TimeoutExpired),
        }
        lookup = load_function('branch_pull_request', namespace)
        return lookup(Path('/project'), branch), runner

    def test_lifecycle_lookup(self):
        for state in ('OPEN', 'MERGED', 'CLOSED'):
            with self.subTest(state=state):
                result, runner = self.lookup(SimpleNamespace(returncode=0, stdout=json.dumps({
                    'url': 'https://github.com/example/repo/pull/1',
                    'state': state, 'autoMergeRequest': {'enabledAt': 'now'},
                })))
                self.assertEqual(result['state'], state)
                self.assertTrue(result['autoMergeEnabled'])
                self.assertEqual(
                    runner.call_args.args[1:5],
                    ('pr', 'view', 'feature/rebased-work', '--json'),
                )

    def test_absent_or_invalid_response(self):
        for code, output in ((1, ''), (0, 'not json'), (0, 'null'), (0, '{}')):
            with self.subTest(code=code, output=output):
                result, _ = self.lookup(SimpleNamespace(returncode=code, stdout=output))
                self.assertIsNone(result)

    def test_lookup_failure_does_not_break_git_status(self):
        for error in (OSError('missing gh'), subprocess.TimeoutExpired('gh', 10)):
            with self.subTest(error=error):
                result, _ = self.lookup(error=error)
                self.assertIsNone(result)

    def test_creation_retains_pr_when_auto_merge_fails(self):
        async def run():
            url = 'https://github.com/example/repo/pull/1'
            namespace = {
                'Request': object, 'asyncio': asyncio,
                'resolve_active_workspace': AsyncMock(return_value=Path('/project')),
                'sys': sys, 'watch_pull_request_merge': Mock(),
                'shutil': SimpleNamespace(which=lambda name: '/bin/gh'),
                'mutation_lock': asyncio.Lock(),
                'subprocess': subprocess,
                'github_cli_result': Mock(side_effect=[
                    SimpleNamespace(returncode=0, stdout=url),
                    SimpleNamespace(returncode=1, stderr='auto-merge unavailable'),
                ]),
                'commit': AsyncMock(),
                'git_error': lambda result, fallback: result.stderr,
                'git_status': lambda project: {
                    'pullRequest': None, 'hasRemote': True, 'hasUpstream': True, 'ahead': 0,
                },
            }
            create = load_function('create_pull_request', namespace)
            request = SimpleNamespace(json=AsyncMock(return_value={
                'title': 'Fix', 'base': 'main', 'description': 'Fix the bug',
                'autoMergeMethod': 'squash',
            }))
            response = await create('project', request)
            self.assertEqual(response['status']['pullRequest']['state'], 'OPEN')
            self.assertEqual(response['status']['pullRequest']['url'], url)
            self.assertFalse(response['autoMergeEnabled'])
            self.assertTrue(response['autoMergeMonitoring'])
            namespace['watch_pull_request_merge'].assert_called_once_with(
                Path('/project'), url, '--squash'
            )
            self.assertIn('auto-merge could not be enabled', response['warning'])
        asyncio.run(run())


    def commit_pull_request(self, push, pull_request=None, gh=None):
        calls = []

        def git(project, *args, **kwargs):
            calls.append(args)
            return SimpleNamespace(returncode=0, stdout='', stderr='')

        namespace = {
            'Request': object, 'asyncio': asyncio, 'sys': sys, 'subprocess': subprocess,
            'HTTPException': HTTPError,
            'resolve_active_workspace': AsyncMock(return_value=Path('/project')),
            'watch_pull_request_merge': Mock(),
            'shutil': SimpleNamespace(which=lambda name: '/bin/gh'),
            'mutation_lock': asyncio.Lock(), 'commit': AsyncMock(),
            'git_result': git, 'git_push_result': Mock(side_effect=push),
            'github_cli_result': gh or Mock(return_value=SimpleNamespace(
                returncode=0, stdout='https://github.com/example/repo/pull/2')),
            'git_draft': lambda project, target: {
                'title': 'Fix', 'base': 'main', 'description': '## Summary\n\n- Fix'},
            'git_error': lambda result, fallback: result.stderr or fallback,
            'git_status': lambda project: {
                'isRepo': True, 'hasRemote': True, 'hasUpstream': False, 'branch': 'feature',
                'changedCount': 1, 'ahead': 0, 'pullRequest': pull_request,
            },
        }
        run = load_function('commit_and_create_pull_request', namespace)
        request = SimpleNamespace(json=AsyncMock(return_value={'message': 'Fix'}))
        return namespace, calls, (lambda: asyncio.run(run('project', request)))

    def test_commit_push_and_create_pull_request(self):
        namespace, calls, run = self.commit_pull_request(
            [SimpleNamespace(returncode=0, stdout='', stderr='')])
        response = run()
        self.assertEqual(response['url'], 'https://github.com/example/repo/pull/2')
        self.assertIn('commit', calls[1])
        namespace['git_push_result'].assert_called_once_with(
            Path('/project'), 'push', '--set-upstream', 'origin', 'HEAD')
        args = namespace['github_cli_result'].call_args.args
        self.assertEqual(args[1:4], ('pr', 'create', '--title'))
        self.assertNotIn(('reset', '--soft', 'HEAD~1'), calls)

    def test_failed_push_undoes_commit(self):
        _, calls, run = self.commit_pull_request(
            [SimpleNamespace(returncode=1, stdout='', stderr='permission denied')])
        with self.assertRaises(HTTPError) as raised:
            run()
        self.assertIn('nothing was committed', raised.exception.detail)
        self.assertEqual(calls[-1], ('reset', '--soft', 'HEAD~1'))

    def test_open_pull_request_is_updated_not_recreated(self):
        gh = Mock()
        _, _, run = self.commit_pull_request(
            [SimpleNamespace(returncode=0, stdout='', stderr='')],
            pull_request={'url': 'https://github.com/example/repo/pull/1', 'state': 'OPEN'},
            gh=gh,
        )
        self.assertEqual(run()['url'], 'https://github.com/example/repo/pull/1')
        gh.assert_not_called()

if __name__ == '__main__':
    unittest.main()
