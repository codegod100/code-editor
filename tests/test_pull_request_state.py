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


class PullRequestStateTests(unittest.TestCase):
    def lookup(self, result=None, error=None):
        runner = Mock(return_value=result, side_effect=error)
        namespace = {
            'Path': Path, 'json': json, 'github_cli_result': runner,
            'subprocess': SimpleNamespace(run=runner, TimeoutExpired=subprocess.TimeoutExpired),
        }
        lookup = load_function('branch_pull_request', namespace)
        return lookup(Path('/project'))

    def test_lifecycle_lookup(self):
        for state in ('OPEN', 'MERGED', 'CLOSED'):
            with self.subTest(state=state):
                result = self.lookup(SimpleNamespace(returncode=0, stdout=json.dumps({
                    'url': 'https://github.com/example/repo/pull/1',
                    'state': state, 'autoMergeRequest': {'enabledAt': 'now'},
                })))
                self.assertEqual(result['state'], state)
                self.assertTrue(result['autoMergeEnabled'])

    def test_absent_or_invalid_response(self):
        for code, output in ((1, ''), (0, 'not json'), (0, 'null'), (0, '{}')):
            with self.subTest(code=code, output=output):
                self.assertIsNone(self.lookup(SimpleNamespace(returncode=code, stdout=output)))

    def test_lookup_failure_does_not_break_git_status(self):
        for error in (OSError('missing gh'), subprocess.TimeoutExpired('gh', 10)):
            with self.subTest(error=error):
                self.assertIsNone(self.lookup(error=error))

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


if __name__ == '__main__':
    unittest.main()
