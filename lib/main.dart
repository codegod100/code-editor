import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

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

class FileTreeNode {
  FileTreeNode.directory(this.name, this.path)
    : isDirectory = true,
      children = [];

  FileTreeNode.file(this.name, this.path)
    : isDirectory = false,
      children = const [];

  final String name;
  final String path;
  final bool isDirectory;
  final List<FileTreeNode> children;
}

const _terminalViewType = 'libghostty-terminal';
bool _terminalViewRegistered = false;

void _registerTerminalView() {
  if (_terminalViewRegistered) return;
  ui_web.platformViewRegistry.registerViewFactory(_terminalViewType, (viewId) {
    return html.IFrameElement()
      ..style.border = '0'
      ..style.height = '100%'
      ..style.width = '100%';
  });
  _terminalViewRegistered = true;
}

class GhosttyTerminal extends StatefulWidget {
  const GhosttyTerminal({
    super.key,
    required this.projectName,
    required this.sessionId,
  });

  final String projectName;
  final int sessionId;

  @override
  State<GhosttyTerminal> createState() => _GhosttyTerminalState();
}

class _GhosttyTerminalState extends State<GhosttyTerminal> {
  @override
  void initState() {
    super.initState();
    _registerTerminalView();
  }

  void _configureFrame(int viewId) {
    final frame =
        ui_web.platformViewRegistry.getViewById(viewId) as html.IFrameElement;
    frame.src =
        'terminal/terminal.html?project=${Uri.encodeQueryComponent(widget.projectName)}&session=${widget.sessionId}';
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(
    key: ValueKey(widget.sessionId),
    viewType: _terminalViewType,
    onPlatformViewCreated: _configureFrame,
  );
}

class TerminalSession {
  const TerminalSession(this.id);

  final int id;

  String get label => 'Terminal $id';
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
  final Set<String> _expandedDirectories = {};
  List<AgentMessage> _messages = const [];
  ProjectSummary? _project;
  String? _path;
  String _savedText = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _agentBusy = false;
  bool _agentStopping = false;
  bool _codexConnected = false;
  String _userName = '';
  String _userEmail = '';
  String? _loginUrl;
  String? _loginCode;
  html.EventSource? _loginEvents;
  final List<TerminalSession> _terminals = [];
  int _nextTerminalId = DateTime.now().microsecondsSinceEpoch;
  int? _activeTerminalId;

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
    final previousProject = _project;
    if (previousProject != null && previousProject.name != project.name) {
      for (final terminal in _terminals) {
        unawaited(_closeTerminal(previousProject.name, terminal.id));
      }
      _terminals.clear();
      _activeTerminalId = null;
    }
    _code.clear();
    setState(() {
      _project = project;
      _path = null;
      _savedText = '';
      _files = const [];
      _expandedDirectories.clear();
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
        _expandedDirectories.addAll(_parentDirectories(path));
      });
      _editorFocus.requestFocus();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Iterable<String> _parentDirectories(String path) sync* {
    final segments = path.split('/');
    for (var index = 1; index < segments.length; index++) {
      yield segments.take(index).join('/');
    }
  }

  List<FileTreeNode> _fileTree() {
    final root = FileTreeNode.directory('', '');
    final directories = <String, FileTreeNode>{'': root};
    for (final filePath in _files) {
      final segments = filePath.split('/');
      var parent = root;
      for (var index = 0; index < segments.length - 1; index++) {
        final directoryPath = segments.take(index + 1).join('/');
        parent = directories.putIfAbsent(directoryPath, () {
          final directory = FileTreeNode.directory(
            segments[index],
            directoryPath,
          );
          parent.children.add(directory);
          return directory;
        });
      }
      parent.children.add(FileTreeNode.file(segments.last, filePath));
    }
    void sortNodes(FileTreeNode node) {
      node.children.sort((left, right) {
        if (left.isDirectory != right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      });
      for (final child in node.children) {
        if (child.isDirectory) sortNodes(child);
      }
    }

    sortNodes(root);
    return root.children;
  }

  List<(FileTreeNode, int)> _visibleTreeNodes() {
    final visible = <(FileTreeNode, int)>[];
    void addNodes(List<FileTreeNode> nodes, int depth) {
      for (final node in nodes) {
        visible.add((node, depth));
        if (node.isDirectory && _expandedDirectories.contains(node.path)) {
          addNodes(node.children, depth + 1);
        }
      }
    }

    addNodes(_fileTree(), 0);
    return visible;
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

  Future<void> _renameProject() async {
    final project = _project;
    if (project == null || _agentBusy) return;
    if (_dirty && !await _confirmDiscard()) return;
    final name = TextEditingController(text: project.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Project name',
            hintText: 'my-project',
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    name.dispose();
    if (newName == null || newName.isEmpty || newName == project.name) return;
    _code.clear();
    setState(() {
      _path = null;
      _savedText = '';
    });
    setState(() => _loading = true);
    try {
      await _request(
        'PATCH',
        '/api/projects/${Uri.encodeComponent(project.name)}',
        {'name': newName},
      );
      await _refreshProjects(select: newName);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _closeProject() async {
    if (_project == null) return;
    if (_dirty && !await _confirmDiscard()) return;
    final project = _project!;
    for (final terminal in _terminals) {
      unawaited(_closeTerminal(project.name, terminal.id));
    }
    _terminals.clear();
    _activeTerminalId = null;
    _code.clear();
    setState(() {
      _project = null;
      _path = null;
      _savedText = '';
      _files = const [];
      _messages = const [];
      _error = null;
    });
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
      if (mounted) {
        setState(() {
          _agentBusy = false;
          _agentStopping = false;
        });
      }
    }
  }

  Future<void> _stopAgent() async {
    if (_project == null || !_agentBusy || _agentStopping) return;
    setState(() {
      _agentStopping = true;
      _error = null;
    });
    try {
      await _request('POST', _projectUrl('/agent/stop'));
    } catch (error) {
      if (mounted) setState(() => _agentStopping = false);
      _showError(error);
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

  void _openTerminal() {
    final project = _project;
    if (project == null) return;
    if (_terminals.isEmpty) {
      _terminals.add(TerminalSession(_nextTerminalId++));
      _activeTerminalId = _terminals.single.id;
    }
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: Text('${project.name} — Terminal'),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(42),
                child: Container(
                  height: 42,
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFF30363D))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: _terminals
                              .map(
                                (terminal) => Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextButton(
                                      onPressed: () => setDialogState(
                                        () => _activeTerminalId = terminal.id,
                                      ),
                                      style: TextButton.styleFrom(
                                        foregroundColor:
                                            _activeTerminalId == terminal.id
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                            : null,
                                      ),
                                      child: Text(terminal.label),
                                    ),
                                    IconButton(
                                      tooltip: 'Close ${terminal.label}',
                                      visualDensity: VisualDensity.compact,
                                      iconSize: 16,
                                      onPressed: () {
                                        setDialogState(() {
                                          final closedIndex = _terminals
                                              .indexOf(terminal);
                                          _terminals.remove(terminal);
                                          if (_activeTerminalId ==
                                                  terminal.id &&
                                              _terminals.isNotEmpty) {
                                            _activeTerminalId =
                                                _terminals[closedIndex
                                                        .clamp(
                                                          0,
                                                          _terminals.length - 1,
                                                        )
                                                        .toInt()]
                                                    .id;
                                          }
                                        });
                                        _closeTerminal(
                                          project.name,
                                          terminal.id,
                                        );
                                        if (_terminals.isEmpty) {
                                          Navigator.pop(context);
                                        }
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              )
                              .toList(),
                        ),
                      ),
                      IconButton(
                        tooltip: 'New terminal',
                        onPressed: () => setDialogState(() {
                          final terminal = TerminalSession(_nextTerminalId++);
                          _terminals.add(terminal);
                          _activeTerminalId = terminal.id;
                        }),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                IconButton(
                  tooltip: 'Close terminal workspace',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            body: IndexedStack(
              index: _terminals.indexWhere(
                (terminal) => terminal.id == _activeTerminalId,
              ),
              children: _terminals
                  .map(
                    (terminal) => GhosttyTerminal(
                      projectName: project.name,
                      sessionId: terminal.id,
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _closeTerminal(String projectName, int sessionId) async {
    try {
      await _request(
        'DELETE',
        '/api/projects/${Uri.encodeComponent(projectName)}/terminal/$sessionId',
      );
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
        onPressed: _project == null ? null : _openTerminal,
        icon: const Icon(Icons.terminal),
        label: const Text('Terminal'),
      ),
      TextButton.icon(
        onPressed: _createProject,
        icon: const Icon(Icons.add),
        label: const Text('Project'),
      ),
      if (_project != null)
        PopupMenuButton<String>(
          tooltip: 'Project actions',
          onSelected: (value) {
            if (value == 'rename') _renameProject();
            if (value == 'close') _closeProject();
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'rename',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.drive_file_rename_outline),
                title: Text('Rename project'),
              ),
            ),
            PopupMenuItem(
              value: 'close',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.close),
                title: Text('Close project'),
              ),
            ),
          ],
          icon: const Icon(Icons.more_vert),
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
            : Builder(
                builder: (context) {
                  final nodes = _visibleTreeNodes();
                  return ListView.builder(
                    itemCount: nodes.length,
                    itemBuilder: (context, index) {
                      final (node, depth) = nodes[index];
                      final isExpanded = _expandedDirectories.contains(
                        node.path,
                      );
                      return ListTile(
                        dense: true,
                        selected: !node.isDirectory && node.path == _path,
                        minLeadingWidth: 24,
                        horizontalTitleGap: 4,
                        contentPadding: EdgeInsets.only(
                          left: 10.0 + depth * 10,
                          right: 8,
                        ),
                        leading: node.isDirectory
                            ? Icon(
                                isExpanded
                                    ? Icons.folder_open_outlined
                                    : Icons.folder_outlined,
                                size: 18,
                                color: const Color(0xFFD6A84A),
                              )
                            : const Icon(Icons.description_outlined, size: 17),
                        title: Text(
                          node.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: node.isDirectory
                            ? () => setState(() {
                                if (isExpanded) {
                                  _expandedDirectories.remove(node.path);
                                } else {
                                  _expandedDirectories.add(node.path);
                                }
                              })
                            : () => _openFile(node.path),
                      );
                    },
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
          tooltip: _agentStopping ? 'Stopping agent' : 'Stop agent',
          visualDensity: VisualDensity.compact,
          onPressed: _agentBusy && !_agentStopping ? _stopAgent : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
        ),
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
                    return Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text(
                            _agentStopping
                                ? 'Stopping Codex…'
                                : 'Codex is working…',
                          ),
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
            Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter, control: true):
                    RunAgentIntent(),
                SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    RunAgentIntent(),
              },
              child: Actions(
                actions: {
                  RunAgentIntent: CallbackAction<RunAgentIntent>(
                    onInvoke: (_) {
                      _runAgent();
                      return null;
                    },
                  ),
                },
                child: TextField(
                  controller: _agentPrompt,
                  enabled: !_agentBusy,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: 'Ask Codex to change this project…',
                    helperText: 'Ctrl/Cmd+Enter to run',
                  ),
                ),
              ),
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
                  onPressed: _agentBusy
                      ? (_agentStopping ? null : _stopAgent)
                      : (_project == null ? null : _runAgent),
                  icon: Icon(
                    _agentBusy
                        ? Icons.stop_circle_outlined
                        : Icons.arrow_upward,
                    size: 18,
                  ),
                  label: Text(_agentBusy ? 'Stop' : 'Run'),
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

class RunAgentIntent extends Intent {
  const RunAgentIntent();
}
