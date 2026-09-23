import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const AgentWorkspaceApp());

class AgentWorkspaceApp extends StatelessWidget {
  const AgentWorkspaceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Codex Workspace',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xFF0D1117),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C9CFF),
        brightness: Brightness.dark,
        surface: const Color(0xFF161B22),
      ),
      dividerColor: const Color(0xFF30363D),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF0D1117),
        border: OutlineInputBorder(),
      ),
    ),
    home: const WorkspaceScreen(),
  );
}

class ProjectSummary {
  const ProjectSummary({
    required this.name,
    required this.isRepo,
    this.branch = '',
  });

  factory ProjectSummary.fromJson(Map<String, dynamic> json) => ProjectSummary(
    name: json['name'] as String,
    isRepo: json['isRepo'] as bool? ?? false,
    branch: json['branch'] as String? ?? '',
  );

  final String name;
  final bool isRepo;
  final String branch;
}

class AgentMessage {
  const AgentMessage({required this.role, required this.text});

  factory AgentMessage.fromJson(Map<String, dynamic> json) => AgentMessage(
    role: json['role'] as String? ?? 'assistant',
    text: json['text'] as String? ?? '',
  );

  final String role;
  final String text;
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final _code = TextEditingController();
  final _agentPrompt = TextEditingController();
  final _editorFocus = FocusNode();
  final _messagesScroll = ScrollController();

  List<ProjectSummary> _projects = const [];
  List<String> _files = const [];
  List<AgentMessage> _messages = const [];
  ProjectSummary? _project;
  String? _path;
  String _savedText = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _agentBusy = false;
  bool _codexConnected = false;
  String _userName = '';
  String _userEmail = '';
  String? _loginUrl;
  String? _loginCode;
  html.EventSource? _loginEvents;

  bool get _dirty => _path != null && _code.text != _savedText;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onEdit);
    _loadInitial();
  }

  void _onEdit() {
    if (mounted) setState(() {});
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String url, [
    Map<String, dynamic>? body,
  ]) async {
    final response = await html.HttpRequest.request(
      url,
      method: method,
      sendData: body == null ? null : jsonEncode(body),
      requestHeaders: body == null
          ? const {}
          : const {'Content-Type': 'application/json'},
    );
    final text = response.responseText ?? '';
    Map<String, dynamic> decoded = {};
    if (text.isNotEmpty) {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) decoded = value;
    }
    final status = response.status ?? 0;
    if (status < 200 || status >= 300) {
      throw StateError(
        decoded['detail']?.toString() ?? 'Request failed ($status)',
      );
    }
    return decoded;
  }

  String _projectUrl(String suffix) =>
      '/api/projects/${Uri.encodeComponent(_project!.name)}$suffix';

  Future<void> _loadInitial() async {
    try {
      final values = await Future.wait([
        _request('GET', '/api/projects'),
        _request('GET', '/api/codex/status'),
        _request('GET', '/api/me'),
      ]);
      final projectValues =
          (values[0]['projects'] as List<dynamic>? ?? const [])
              .map(
                (item) => ProjectSummary.fromJson(item as Map<String, dynamic>),
              )
              .toList();
      if (!mounted) return;
      setState(() {
        _projects = projectValues;
        _codexConnected = values[1]['authenticated'] as bool? ?? false;
        _userName = values[2]['name'] as String? ?? '';
        _userEmail = values[2]['email'] as String? ?? '';
        _loading = false;
      });
      if (projectValues.isNotEmpty) await _selectProject(projectValues.first);
    } catch (error) {
      _showError(error);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshProjects({String? select}) async {
    final response = await _request('GET', '/api/projects');
    final projects = (response['projects'] as List<dynamic>? ?? const [])
        .map((item) => ProjectSummary.fromJson(item as Map<String, dynamic>))
        .toList();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      if (select != null) _project = null;
    });
    if (select != null) {
      final match = projects.where((item) => item.name == select).firstOrNull;
      if (match != null) await _selectProject(match);
    }
  }

  Future<void> _selectProject(ProjectSummary project) async {
    if (_dirty && !await _confirmDiscard()) return;
    _code.clear();
    setState(() {
      _project = project;
      _path = null;
      _savedText = '';
      _files = const [];
      _messages = const [];
      _loading = true;
      _error = null;
    });
    try {
      await Future.wait([_refreshTree(), _loadSession()]);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshTree() async {
    if (_project == null) return;
    final response = await _request('GET', _projectUrl('/tree'));
    if (!mounted) return;
    setState(() {
      _files = (response['files'] as List<dynamic>? ?? const []).cast<String>();
    });
  }

  Future<void> _loadSession() async {
    if (_project == null) return;
    final response = await _request('GET', _projectUrl('/session'));
    if (!mounted) return;
    setState(() {
      _messages = (response['messages'] as List<dynamic>? ?? const [])
          .map((item) => AgentMessage.fromJson(item as Map<String, dynamic>))
          .toList();
    });
    _scrollMessages();
  }

  Future<void> _openFile(String path) async {
    if (_dirty && !await _confirmDiscard()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _request(
        'GET',
        '${_projectUrl('/file')}?path=${Uri.encodeQueryComponent(path)}',
      );
      if (!mounted) return;
      final content = response['content'] as String? ?? '';
      _savedText = content;
      _code.value = TextEditingValue(text: content);
      setState(() {
        _path = path;
      });
      _editorFocus.requestFocus();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_project == null || _path == null || _saving) return;
    final snapshot = _code.text;
    setState(() => _saving = true);
    try {
      await _request('PUT', _projectUrl('/file'), {
        'path': _path,
        'content': snapshot,
      });
      if (mounted) setState(() => _savedText = snapshot);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createProject() async {
    final name = TextEditingController();
    final repo = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add project'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Project name',
                  hintText: 'my-project',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: repo,
                decoration: const InputDecoration(
                  labelText: 'Repository URL (optional)',
                  hintText: 'https://git.example.com/team/project.git',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, [name.text.trim(), repo.text.trim()]),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    name.dispose();
    repo.dispose();
    if (values == null || values.first.isEmpty) return;
    setState(() => _loading = true);
    try {
      await _request('POST', '/api/projects', {
        'name': values[0],
        'repoUrl': values[1],
      });
      await _refreshProjects(select: values[0]);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _connectCodex() {
    _loginEvents?.close();
    setState(() {
      _loginUrl = null;
      _loginCode = null;
      _error = null;
    });
    final source = html.EventSource('/api/codex/login');
    _loginEvents = source;
    source.onMessage.listen((event) {
      final value = jsonDecode(event.data as String) as Map<String, dynamic>;
      final stage = value['stage'];
      if (stage == 'code') {
        setState(() {
          _loginUrl = value['verificationUrl'] as String?;
          _loginCode = value['userCode'] as String?;
        });
      } else if (stage == 'complete') {
        source.close();
        setState(() {
          _codexConnected = value['success'] as bool? ?? false;
          _loginUrl = null;
          _loginCode = null;
        });
      } else if (stage == 'error') {
        source.close();
        _showError(value['error']?.toString() ?? 'Codex login failed');
      }
    });
    source.onError.listen((_) {
      if (!_codexConnected && _loginCode == null) {
        _showError('Codex login connection closed');
      }
    });
  }

  Future<void> _runAgent() async {
    if (_project == null || _agentBusy) return;
    final prompt = _agentPrompt.text.trim();
    if (prompt.isEmpty) return;
    if (!_codexConnected) {
      _showError('Connect Codex before starting an agent turn.');
      return;
    }
    if (_dirty) {
      _showError('Save the open file before starting an agent turn.');
      return;
    }
    setState(() {
      _agentBusy = true;
      _agentPrompt.clear();
      _messages = [..._messages, AgentMessage(role: 'user', text: prompt)];
      _error = null;
    });
    _scrollMessages();
    try {
      final response = await _request('POST', _projectUrl('/agent'), {
        'prompt': prompt,
      });
      if (!mounted) return;
      setState(() {
        _messages = (response['messages'] as List<dynamic>? ?? const [])
            .map((item) => AgentMessage.fromJson(item as Map<String, dynamic>))
            .toList();
      });
      await _refreshTree();
      if (_path != null) await _openFile(_path!);
      _scrollMessages();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _agentBusy = false);
    }
  }

  Future<void> _resetAgent() async {
    if (_project == null || _agentBusy) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Start a new agent thread?'),
            content: const Text(
              'The current project files stay intact. Conversation history is cleared.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('New thread'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await _request('DELETE', _projectUrl('/session'));
      if (mounted) setState(() => _messages = const []);
    } catch (error) {
      _showError(error);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            content: Text(_path ?? ''),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
  }

  void _logout() => html.window.location.assign('/auth/logout');

  String get _userInitial {
    final value = _userName.trim().isEmpty
        ? _userEmail.trim()
        : _userName.trim();
    return value.isEmpty ? '?' : value.characters.first.toUpperCase();
  }

  void _scrollMessages() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_messagesScroll.hasClients) {
        _messagesScroll.animateTo(
          _messagesScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _loginEvents?.close();
    _code.removeListener(_onEdit);
    _code.dispose();
    _agentPrompt.dispose();
    _editorFocus.dispose();
    _messagesScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
      SingleActivator(LogicalKeyboardKey.keyS, meta: true): SaveIntent(),
    },
    child: Actions(
      actions: {
        SaveIntent: CallbackAction<SaveIntent>(
          onInvoke: (_) {
            _save();
            return null;
          },
        ),
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: Column(
          children: [
            if (_error != null)
              MaterialBanner(
                content: SelectableText(_error!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            if (_loginCode != null) _buildLoginBanner(),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _project == null ? _buildEmptyState() : _buildWorkspace(),
            ),
          ],
        ),
      ),
    ),
  );

  PreferredSizeWidget _buildAppBar() => AppBar(
    titleSpacing: 16,
    title: Row(
      children: [
        const Icon(Icons.auto_awesome, size: 22),
        const SizedBox(width: 10),
        const Text('Codex Workspace'),
        const SizedBox(width: 24),
        if (_projects.isNotEmpty)
          DropdownButtonHideUnderline(
            child: DropdownButton<ProjectSummary>(
              value: _project,
              hint: const Text('Select project'),
              items: _projects
                  .map(
                    (project) => DropdownMenuItem(
                      value: project,
                      child: Row(
                        children: [
                          Icon(
                            project.isRepo
                                ? Icons.account_tree_outlined
                                : Icons.folder_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(project.name),
                          if (project.branch.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              project.branch,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (project) {
                if (project != null) _selectProject(project);
              },
            ),
          ),
      ],
    ),
    actions: [
      TextButton.icon(
        onPressed: _createProject,
        icon: const Icon(Icons.add),
        label: const Text('Project'),
      ),
      const SizedBox(width: 8),
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: _codexConnected
            ? const Chip(
                avatar: Icon(Icons.check_circle, size: 16),
                label: Text('Codex connected'),
              )
            : FilledButton.tonalIcon(
                onPressed: _connectCodex,
                icon: const Icon(Icons.link),
                label: const Text('Connect Codex'),
              ),
      ),
      PopupMenuButton<String>(
        tooltip: _userName.isEmpty ? 'Pocket ID account' : _userName,
        onSelected: (value) {
          if (value == 'logout') _logout();
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text(_userInitial)),
              title: Text(_userName),
              subtitle: _userEmail.isEmpty ? null : Text(_userEmail),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'logout',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout),
              title: Text('Log out'),
            ),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(radius: 14, child: Text(_userInitial)),
              if (_userName.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(_userName),
              ],
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _buildLoginBanner() => MaterialBanner(
    leading: const Icon(Icons.login),
    content: SelectableText(
      'Open the Codex sign-in page and enter code $_loginCode.',
    ),
    actions: [
      FilledButton(
        onPressed: _loginUrl == null
            ? null
            : () => html.window.open(_loginUrl!, 'codex-login'),
        child: const Text('Open sign-in'),
      ),
    ],
  );

  Widget _buildEmptyState() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_copy_outlined, size: 54),
              const SizedBox(height: 20),
              Text(
                'Open a durable workspace',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              const Text(
                'Create a folder or clone a repository. Files and Codex threads are stored on the project disk and survive redeploys.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _createProject,
                icon: const Icon(Icons.add),
                label: const Text('Add project'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildWorkspace() => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 900) {
        return DefaultTabController(
          length: 3,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Files'),
                  Tab(text: 'Editor'),
                  Tab(text: 'Agent'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [_buildFiles(), _buildEditor(), _buildAgent()],
                ),
              ),
            ],
          ),
        );
      }
      return Row(
        children: [
          SizedBox(width: 250, child: _buildFiles()),
          const VerticalDivider(width: 1),
          Expanded(child: _buildEditor()),
          const VerticalDivider(width: 1),
          SizedBox(width: 390, child: _buildAgent()),
        ],
      );
    },
  );

  Widget _panelHeader(String title, List<Widget> actions) => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
    ),
    child: Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const Spacer(),
        ...actions,
      ],
    ),
  );

  Widget _buildFiles() => Column(
    children: [
      _panelHeader('EXPLORER', [
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          onPressed: _refreshTree,
          icon: const Icon(Icons.refresh, size: 18),
        ),
      ]),
      Expanded(
        child: _files.isEmpty
            ? const Center(child: Text('No files'))
            : ListView.builder(
                itemCount: _files.length,
                itemBuilder: (context, index) {
                  final file = _files[index];
                  final depth = '/'.allMatches(file).length;
                  return ListTile(
                    dense: true,
                    selected: file == _path,
                    contentPadding: EdgeInsets.only(
                      left: 10.0 + depth * 10,
                      right: 8,
                    ),
                    leading: const Icon(Icons.description_outlined, size: 17),
                    title: Text(
                      file.split('/').last,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: depth == 0
                        ? null
                        : Text(
                            file,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10),
                          ),
                    onTap: () => _openFile(file),
                  );
                },
              ),
      ),
    ],
  );

  Widget _buildEditor() => Column(
    children: [
      _panelHeader(
        _path == null ? 'EDITOR' : '${_path!}${_dirty ? ' •' : ''}',
        [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Save (Ctrl/Cmd+S)',
              visualDensity: VisualDensity.compact,
              onPressed: _path == null ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
            ),
        ],
      ),
      Expanded(
        child: _path == null
            ? const Center(child: Text('Select a file from the explorer'))
            : Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _code,
                  focusNode: _editorFocus,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
      ),
    ],
  );

  Widget _buildAgent() => Column(
    children: [
      _panelHeader('AGENT', [
        IconButton(
          tooltip: 'New thread',
          visualDensity: VisualDensity.compact,
          onPressed: _resetAgent,
          icon: const Icon(Icons.add_comment_outlined, size: 18),
        ),
      ]),
      Expanded(
        child: _messages.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.auto_awesome_outlined, size: 42),
                    const SizedBox(height: 16),
                    Text(
                      'Ask Codex to work in ${_project?.name}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'It can inspect the repository, edit files, and run checks inside this project.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            : ListView.builder(
                controller: _messagesScroll,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length + (_agentBusy ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _messages.length) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Codex is working…'),
                        ],
                      ),
                    );
                  }
                  final message = _messages[index];
                  final user = message.role == 'user';
                  return Align(
                    alignment: user
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 340),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: user
                            ? const Color(0xFF263659)
                            : const Color(0xFF161B22),
                        border: Border.all(color: const Color(0xFF30363D)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectableText(message.text),
                    ),
                  );
                },
              ),
      ),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFF30363D))),
        ),
        child: Column(
          children: [
            TextField(
              controller: _agentPrompt,
              enabled: !_agentBusy,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: 'Ask Codex to change this project…',
              ),
              onSubmitted: (_) => _runAgent(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _codexConnected ? 'Workspace write' : 'Codex not connected',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _agentBusy || _project == null ? null : _runAgent,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  label: const Text('Run'),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class SaveIntent extends Intent {
  const SaveIntent();
}
