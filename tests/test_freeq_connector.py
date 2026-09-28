"""Exercise Claude Code's FreeQ connector without starting the Modal deployment."""
import asyncio
import json
from pathlib import Path
import unittest
from unittest.mock import AsyncMock

from test_pull_request_state import HTTPError, load_function


def fake_tool(name, description, schema):
    def register(handler):
        handler.tool_name, handler.schema = name, schema
        return handler
    return register


class FreeqConnectorTests(unittest.TestCase):
    def connector(self, **overrides):
        namespace = {
            'Path': Path, 'json': json, 'HTTPException': HTTPError, 'tool': fake_tool,
            'create_sdk_mcp_server': lambda name, tools: {'name': name, 'tools': {t.tool_name: t for t in tools}},
            'freeq_default_channel': '#tasks', 'freeq_default_capability': 'prime_agent',
            'start_freeq_handoff': AsyncMock(return_value={'taskId': 'task-1', 'status': 'offered'}),
            'list_freeq_bots': AsyncMock(return_value={'bots': []}),
            'get_freeq_handoff': AsyncMock(return_value={'taskId': 'task-1', 'status': 'claimed'}),
            **overrides,
        }
        for helper in ('freeq_tool_result', 'freeq_tool_error'):
            load_function(helper, namespace)
        connector = load_function('freeq_connector', namespace)
        server = connector('demo', Path('/workspace/demo'), Path('/worktree'), {'did': 'did:plc:me', 'handle': 'me.test'})
        return server, namespace

    def call(self, server, name, args):
        return asyncio.run(server['tools'][name](args))

    def test_exposes_handoff_tools(self):
        server, _ = self.connector()
        self.assertEqual(server['name'], 'freeq')
        self.assertEqual(set(server['tools']), {'list_bots', 'handoff', 'handoff_status'})

    def test_handoff_defaults_to_tasks_channel_and_thread_checkout(self):
        server, namespace = self.connector()
        result = self.call(server, 'handoff', {'title': 'Fix it', 'context': 'Details'})
        self.assertEqual(json.loads(result['content'][0]['text'])['taskId'], 'task-1')
        args, kwargs = namespace['start_freeq_handoff'].call_args
        self.assertEqual(args, ('demo', Path('/workspace/demo'), Path('/worktree'), {'did': 'did:plc:me', 'handle': 'me.test'}))
        self.assertEqual(kwargs['channel'], '#tasks')
        self.assertEqual(kwargs['capability'], 'prime_agent')
        self.assertEqual((kwargs['title'], kwargs['context']), ('Fix it', 'Details'))

    def test_errors_are_reported_to_claude(self):
        failing = AsyncMock(side_effect=HTTPError(409, 'commit first'))
        server, _ = self.connector(start_freeq_handoff=failing)
        result = self.call(server, 'handoff', {'title': 'x', 'context': 'y'})
        self.assertTrue(result['is_error'])
        self.assertIn('commit first', result['content'][0]['text'])

    def test_status_looks_up_task(self):
        server, namespace = self.connector()
        result = self.call(server, 'handoff_status', {'task_id': 'task-1'})
        self.assertEqual(json.loads(result['content'][0]['text'])['status'], 'claimed')
        namespace['get_freeq_handoff'].assert_awaited_with('demo', 'task-1')


if __name__ == '__main__':
    unittest.main()
