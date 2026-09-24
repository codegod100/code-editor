import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _deployedVersion = String.fromEnvironment('APP_RELEASE');

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
    this.repoUrl = '',
  });

  factory ProjectSummary.fromJson(Map<String, dynamic> json) => ProjectSummary(
    name: json['name'] as String,
    isRepo: json['isRepo'] as bool? ?? false,
    branch: json['branch'] as String? ?? '',
    repoUrl: json['repoUrl'] as String? ?? '',
  );

  final String name;
  final bool isRepo;
  final String branch;
  final String repoUrl;
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

class AgentThreadHistory {
  const AgentThreadHistory({
    required this.messages,
    this.name,
    this.threadId,
    this.archivedAt,
  });

  factory AgentThreadHistory.fromJson(Map<String, dynamic> json) =>
      AgentThreadHistory(
        name: (json['name'] ?? json['title']) as String?,
        threadId: json['threadId'] as String?,
        archivedAt: json['archivedAt'] as String?,
        messages: (json['messages'] as List<dynamic>? ?? const [])
            .map((item) => AgentMessage.fromJson(item as Map<String, dynamic>))
            .toList(),
      );

  final String? name;
  final String? threadId;
  final String? archivedAt;
  final List<AgentMessage> messages;

  String get title {
    if (name?.trim().isNotEmpty == true) return name!.trim();
    final prompt = messages
        .where((message) => message.role == 'user')
        .firstOrNull;
    if (prompt == null || prompt.text.trim().isEmpty) return 'Untitled thread';
    return prompt.text.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}

class AgentWorkThread {
  const AgentWorkThread({
    required this.id,
    required this.title,
    required this.messages,
    this.updatedAt,
  });

  factory AgentWorkThread.fromJson(Map<String, dynamic> json) => AgentWorkThread(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? 'Work thread',
    updatedAt: json['updatedAt'] as String?,
    messages: (json['messages'] as List<dynamic>? ?? const [])
        .map((item) => AgentMessage.fromJson(item as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final String title;
  final String? updatedAt;
  final List<AgentMessage> messages;

  AgentWorkThread withMessages(
    List<AgentMessage> value, {
    String? newTitle,
  }) => AgentWorkThread(
    id: id,
    title: newTitle ?? title,
    messages: value,
    updatedAt: updatedAt,
  );
}

class FreeqBot {
  const FreeqBot({
    required this.did,
    required this.name,
    required this.description,
    required this.capabilities,
    this.version = '',
  });

  factory FreeqBot.fromJson(Map<String, dynamic> json) => FreeqBot(
    did: json['did'] as String? ?? '',
    name: json['name'] as String? ?? 'Unknown bot',
    description: json['description'] as String? ?? '',
    capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .toList(),
    version: json['version'] as String? ?? '',
  );

  final String did;
  final String name;
  final String description;
  final List<String> capabilities;
  final String version;
}

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

class GitStatus {
  const GitStatus({
    required this.isRepo,
    required this.files,
    this.branch = '',
    this.ahead = 0,
    this.behind = 0,
    this.hasRemote = false,
    this.prAvailable = false,
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
    prAvailable: json['prAvailable'] as bool? ?? false,
  );

  final bool isRepo;
  final String branch;
  final List<GitChange> files;
  final int ahead;
  final int behind;
  final bool hasRemote;
  final bool prAvailable;
  int get changedCount => files.length;
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

class SyntaxRange {
  const SyntaxRange({
    required this.start,
    required this.end,
    required this.kind,
  });

  factory SyntaxRange.fromJson(Map<Object?, Object?> json) => SyntaxRange(
    start: json['start'] as int,
    end: json['end'] as int,
    kind: json['kind'] as String,
  );

  final int start;
  final int end;
  final String kind;
}

class SyntaxHighlightingController extends TextEditingController {
  SyntaxHighlightingController({super.text});

  List<SyntaxRange> _ranges = const [];

  void setRanges(List<SyntaxRange> ranges) {
    _ranges = ranges;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final children = <TextSpan>[];
    var cursor = 0;
    for (final range in _ranges) {
      if (range.start < cursor || range.end > text.length) continue;
      if (range.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, range.start)));
      }
      children.add(
        TextSpan(
          text: text.substring(range.start, range.end),
          style: _styleFor(range.kind),
        ),
      );
      cursor = range.end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }

  TextStyle _styleFor(String kind) => switch (kind) {
    'comment' => const TextStyle(
      color: Color(0xFF8B949E),
      fontStyle: FontStyle.italic,
    ),
    'string' => const TextStyle(color: Color(0xFFA5D6FF)),
    'escape' => const TextStyle(color: Color(0xFFFFC680)),
    'number' => const TextStyle(color: Color(0xFF79C0FF)),
    'constant' => const TextStyle(color: Color(0xFFFF7B72)),
    'keyword' => const TextStyle(
      color: Color(0xFFFF7B72),
      fontWeight: FontWeight.w600,
    ),
    'definition' => const TextStyle(color: Color(0xFFD2A8FF)),
    _ => const TextStyle(color: Color(0xFFE6EDF3)),
  };
}

const _terminalViewType = 'libghostty-terminal';
bool _terminalViewRegistered = false;
final _terminalInteractionEnabled = ValueNotifier<bool>(true);

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
  html.IFrameElement? _frame;

  @override
  void initState() {
    super.initState();
    _registerTerminalView();
    _terminalInteractionEnabled.addListener(_updatePointerEvents);
  }

  void _configureFrame(int viewId) {
    final frame =
        ui_web.platformViewRegistry.getViewById(viewId) as html.IFrameElement;
    _frame = frame;
    frame.src =
        'terminal/terminal.html?project=${Uri.encodeQueryComponent(widget.projectName)}&session=${widget.sessionId}';
    _updatePointerEvents();
  }

  void _updatePointerEvents() {
    _frame?.style.pointerEvents = _terminalInteractionEnabled.value
        ? 'auto'
        : 'none';
  }

  @override
  void dispose() {
    _terminalInteractionEnabled.removeListener(_updatePointerEvents);
    super.dispose();
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

class _CommitDialog extends StatefulWidget {
  const _CommitDialog({
    required this.changedCount,
    required this.suggestedMessage,
  });

  final int changedCount;
  final String suggestedMessage;

  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<_CommitDialog> {
  late final TextEditingController _message = TextEditingController(
    text: widget.suggestedMessage,
  );

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      'Commit ${widget.changedCount} changed file${widget.changedCount == 1 ? '' : 's'}',
    ),
    content: TextField(
      controller: _message,
      autofocus: true,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _commit(),
      decoration: const InputDecoration(
        labelText: 'Commit message',
        helperText: 'Chosen by Codex; edit if needed.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _message.text.trim().isEmpty ? null : _commit,
        child: const Text('Commit'),
      ),
    ],
  );

  void _commit() {
    final message = _message.text.trim();
    if (message.isNotEmpty) Navigator.pop(context, message);
  }
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

enum _AgentPanelTab { chat, sourceControl, freeq }

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  static const _lastProjectStorageKey = 'cloud-code-editor.last-project';
  static const _lastFreeqCapabilityStorageKey =
      'cloud-code-editor.last-freeq-capability';

  final _code = SyntaxHighlightingController();
  final _agentPrompt = TextEditingController();
  final _editorFocus = FocusNode();
  final _messagesScroll = ScrollController();

  List<ProjectSummary> _projects = const [];
  List<String> _files = const [];
  final Set<String> _expandedDirectories = {};
  List<AgentMessage> _messages = const [];
  List<AgentWorkThread> _workThreads = const [];
  String? _activeWorkThreadId;
  final Set<String> _runningWorkThreads = <String>{};
  final Set<String> _stoppingWorkThreads = <String>{};
  final Map<String, html.EventSource> _agentEventSources = {};
  final Map<String, List<String>> _workThreadActivity = {};
  final Map<String, String> _workThreadStreams = {};
  List<AgentThreadHistory> _threadHistory = const [];
  List<Map<String, dynamic>> _freeqHandoffs = const [];
  ProjectSummary? _project;
  String? _path;
  String _savedText = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _agentBusy = false;
  bool _agentStopping = false;
  final Set<String> _freeqReviewBusy = <String>{};
  bool _showCompletedHandoffs = false;
  _AgentPanelTab _agentPanelTab = _AgentPanelTab.chat;
  List<String> _agentActivity = const [];
  String _streamedResponse = '';
  bool _codexConnected = false;
  GitStatus? _gitStatus;
  bool _gitBusy = false;
  bool _diffBusy = false;
  String _userName = '';
  String _userEmail = '';
  String? _loginUrl;
  String? _loginCode;
  html.EventSource? _loginEvents;
  Timer? _freeqPoller;
  final List<TerminalSession> _terminals = [];
  int _nextTerminalId = DateTime.now().microsecondsSinceEpoch;
  int? _activeTerminalId;
  bool _terminalVisible = false;
  double _terminalHeight = 300;
  Timer? _highlightTimer;
  int _highlightRequest = 0;
  bool _applyingSyntaxHighlights = false;

  bool get _dirty => _path != null && _code.text != _savedText;

  bool get _isMobile => MediaQuery.sizeOf(context).width < 700;

  double _dialogWidth(BuildContext context, double maximum) =>
      (MediaQuery.sizeOf(context).width - 48).clamp(280, maximum).toDouble();

  double _dialogHeight(BuildContext context, double maximum) =>
      (MediaQuery.sizeOf(context).height - 180)
          .clamp(240, maximum)
          .toDouble();

  @override
  void initState() {
    super.initState();
    _code.addListener(_onEdit);
    _loadInitial();
  }

  void _onEdit() {
    if (_applyingSyntaxHighlights) return;
    _scheduleSyntaxHighlighting();
    if (mounted) setState(() {});
  }

  void _scheduleSyntaxHighlighting() {
    _highlightTimer?.cancel();
    final request = ++_highlightRequest;
    _highlightTimer = Timer(const Duration(milliseconds: 120), () async {
      final language = _languageForPath(_path);
      if (language == null || _code.text.isEmpty) {
        _applySyntaxRanges(request, const []);
        return;
      }
      try {
        final bridge = js_util.getProperty<Object?>(
          html.window,
          'TreeSitterHighlighter',
        );
        if (bridge == null) {
          throw StateError('Tree-sitter assets were not loaded');
        }
        final promise = js_util.callMethod<Object>(bridge, 'highlight', [
          _code.text,
          language,
        ]);
        final rawRanges = await js_util.promiseToFuture<Object?>(promise);
        final values = js_util.dartify(rawRanges) as List<Object?>;
        _applySyntaxRanges(
          request,
          values
              .map(
                (value) => SyntaxRange.fromJson(
                  js_util.dartify(value) as Map<Object?, Object?>,
                ),
              )
              .toList(),
        );
      } catch (error) {
        if (request == _highlightRequest) _showError(error);
      }
    });
  }

  String? _languageForPath(String? path) {
    if (path == null) return null;
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'dart' => 'dart',
      'js' || 'mjs' || 'cjs' || 'jsx' => 'javascript',
      'ts' => 'typescript',
      'tsx' => 'tsx',
      'json' => 'json',
      'py' => 'python',
      'html' || 'htm' => 'html',
      'css' => 'css',
      'sh' || 'bash' || 'zsh' => 'bash',
      _ => null,
    };
  }

  void _applySyntaxRanges(int request, List<SyntaxRange> ranges) {
    if (!mounted || request != _highlightRequest) return;
    _applyingSyntaxHighlights = true;
    _code.setRanges(ranges);
    _applyingSyntaxHighlights = false;
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

  String? get _lastProjectName =>
      html.window.localStorage[_lastProjectStorageKey];

  String? get _lastFreeqCapability =>
      html.window.localStorage[_lastFreeqCapabilityStorageKey];

  void _rememberProject(ProjectSummary project) {
    html.window.localStorage[_lastProjectStorageKey] = project.name;
  }

  void _forgetLastProject() {
    html.window.localStorage.remove(_lastProjectStorageKey);
  }

  void _rememberFreeqCapability(String capability) {
    html.window.localStorage[_lastFreeqCapabilityStorageKey] = capability;
  }

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
        _userEmail = values[2]['did'] as String? ?? '';
        _loading = false;
      });
      if (projectValues.isNotEmpty) {
        final rememberedProject = projectValues
            .where((project) => project.name == _lastProjectName)
            .firstOrNull;
        await _selectProject(rememberedProject ?? projectValues.first);
      }
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
    if (_project?.name != project.name && _runningWorkThreads.isNotEmpty) {
      _showError('Stop running work threads before switching projects.');
      return;
    }
    if (_dirty && !await _confirmDiscard()) return;
    final previousProject = _project;
    if (previousProject != null && previousProject.name != project.name) {
      for (final terminal in _terminals) {
        unawaited(_closeTerminal(previousProject.name, terminal.id));
      }
      _terminals.clear();
      _activeTerminalId = null;
      _terminalVisible = false;
    }
    _code.clear();
    setState(() {
      _project = project;
      _path = null;
      _savedText = '';
      _files = const [];
      _expandedDirectories.clear();
      _messages = const [];
      _workThreads = const [];
      _activeWorkThreadId = null;
      _threadHistory = const [];
      _freeqHandoffs = const [];
      _agentPanelTab = _AgentPanelTab.chat;
      _loading = true;
      _error = null;
    });
    _rememberProject(project);
    try {
      await Future.wait([_refreshTree(), _loadSession(), _refreshGitStatus()]);
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
      _workThreads = (response['threads'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AgentWorkThread.fromJson)
          .toList();
      _activeWorkThreadId = response['activeThreadId'] as String?;
      _messages = (response['messages'] as List<dynamic>? ?? const [])
          .map((item) => AgentMessage.fromJson(item as Map<String, dynamic>))
          .toList();
      _threadHistory = (response['history'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AgentThreadHistory.fromJson)
          .toList()
          .reversed
          .toList();
      _freeqHandoffs = (response['handoffs'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      _agentBusy = _runningWorkThreads.contains(_activeWorkThreadId);
      _agentStopping = _stoppingWorkThreads.contains(_activeWorkThreadId);
      _agentActivity = _workThreadActivity[_activeWorkThreadId] ?? const [];
      _streamedResponse = _workThreadStreams[_activeWorkThreadId] ?? '';
    });
    _ensureFreeqPolling();
    _scrollMessages();
  }

  void _ensureFreeqPolling() {
    _freeqPoller?.cancel();
    if (_project == null ||
        !_freeqHandoffs.any(
          (item) => !{
            'complete',
            'incorporated',
            'fail',
            'decline',
            'timeout',
          }.contains(item['status']),
        ))
      return;
    _freeqPoller = Timer.periodic(const Duration(seconds: 5), (_) async {
      final project = _project;
      if (project == null) return;
      final pending = _freeqHandoffs
          .where(
            (item) => !{
              'complete',
              'incorporated',
              'fail',
              'decline',
              'timeout',
            }.contains(item['status']),
          )
          .toList();
      for (final handoff in pending) {
        final taskId = handoff['taskId']?.toString();
        if (taskId == null || taskId.isEmpty) continue;
        try {
          final update = await _request(
            'GET',
            '/api/projects/${Uri.encodeComponent(project.name)}/freeq/handoffs/${Uri.encodeComponent(taskId)}',
          );
          if (!mounted) return;
          setState(() {
            _freeqHandoffs = _freeqHandoffs
                .map(
                  (item) =>
                      item['taskId'] == taskId ? {...item, ...update} : item,
                )
                .toList();
          });
          if ({
            'incorporating',
            'complete',
            'fail',
            'decline',
            'timeout',
          }.contains(update['status'])) {
            await _loadSession();
          }
        } catch (_) {
          // A temporary discovery outage should not discard an in-flight task.
        }
      }
      _ensureFreeqPolling();
    });
  }

  Future<void> _openFreeqHandoff() async {
    if (_project == null || _agentBusy) return;
    final server = TextEditingController(text: 'wss://irc.freeq.at/irc');
    final channel = TextEditingController(text: '#tasks');
    final task = TextEditingController(text: _agentPrompt.text);
    final handoffContext = TextEditingController();
    List<FreeqBot> bots = const [];
    List<String> capabilities = const [];
    String? capability;
    String? discoveryError;
    bool discovering = true;
    bool discoveryStarted = false;
    Future<void> discover(StateSetter setDialogState) async {
      setDialogState(() {
        discovering = true;
        discoveryError = null;
      });
      try {
        final response = await _request(
          'GET',
          '/api/freeq/bots?server=${Uri.encodeQueryComponent(server.text.trim())}',
        );
        bots = (response['bots'] as List<dynamic>? ?? const [])
            .map((item) => FreeqBot.fromJson(item as Map<String, dynamic>))
            .where((bot) => bot.did.isNotEmpty && bot.capabilities.isNotEmpty)
            .toList();
        capabilities = bots.expand((bot) => bot.capabilities).toSet().toList()
          ..sort();
        final rememberedCapability = _lastFreeqCapability;
        capability = capabilities.contains(rememberedCapability)
            ? rememberedCapability
            : capabilities.isEmpty
            ? null
            : capabilities.first;
      } catch (error) {
        discoveryError = error.toString();
      } finally {
        setDialogState(() => discovering = false);
      }
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          if (!discoveryStarted) {
            discoveryStarted = true;
            unawaited(discover(setDialogState));
          }
          return AlertDialog(
            title: const Text('Hand off to a FreeQ bot'),
            content: SizedBox(
              width: _dialogWidth(dialogContext, 520),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: server,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: 'FreeQ server (canonical)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: channel,
                      decoration: const InputDecoration(labelText: 'Channel'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: task,
                      maxLines: 2,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: const InputDecoration(labelText: 'Task'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: handoffContext,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Context for the bot (optional)',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (discovering) const LinearProgressIndicator(),
                    if (discoveryError != null)
                      Text(
                        discoveryError!,
                        style: const TextStyle(color: Color(0xFFFF7B72)),
                      ),
                    if (!discovering && discoveryError == null) ...[
                      DropdownButtonFormField<String>(
                        value: capability,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Capability offered in this channel',
                        ),
                        items: capabilities
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(
                                  item,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (item) =>
                            setDialogState(() => capability = item),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${bots.length} published bot${bots.length == 1 ? '' : 's'} discovered. This is an open offer: any bot in the selected channel that supports the capability may claim it. The editor publishes a clean snapshot to public AgentGit; the worker pushes its changes there for your review.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: discovering ? null : () => discover(setDialogState),
                child: const Text('Refresh bots'),
              ),
              FilledButton(
                onPressed: capability == null || task.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Hand off'),
              ),
            ],
          );
        },
      ),
    );
    final usedCapability = capability;
    if (accepted != true || usedCapability == null) {
      server.dispose();
      channel.dispose();
      task.dispose();
      handoffContext.dispose();
      return;
    }
    try {
      final handoff = await _request('POST', _projectUrl('/freeq/handoffs'), {
        'server': server.text.trim(),
        'channel': channel.text.trim(),
        'capability': usedCapability,
        'title': task.text.trim(),
        'context': handoffContext.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _freeqHandoffs = [..._freeqHandoffs, handoff];
        _agentPanelTab = _AgentPanelTab.freeq;
        _messages = [
          ..._messages,
          AgentMessage(
            role: 'user',
            text:
                'Open FreeQ handoff in ${channel.text.trim()}: ${task.text.trim()}',
          ),
        ];
      });
      _rememberFreeqCapability(usedCapability);
      _ensureFreeqPolling();
      _scrollMessages();
    } catch (error) {
      _showError(error);
    }
    server.dispose();
    channel.dispose();
    task.dispose();
    handoffContext.dispose();
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

  String _freeqStatusLabel(String status) => switch (status) {
    'offered' => 'Waiting for a bot',
    'claimed' || 'accepted' => 'Claimed',
    'incorporating' => 'Adding result to this thread',
    'waiting_to_incorporate' => 'Waiting to add result',
    'complete' => 'Completed',
    'incorporated' => 'Incorporated',
    'fail' => 'Failed',
    'decline' => 'Declined',
    'timeout' => 'Timed out',
    _ => status.replaceAll('_', ' '),
  };

  IconData _freeqStatusIcon(String status) => switch (status) {
    'offered' => Icons.schedule_outlined,
    'claimed' || 'accepted' => Icons.person_pin_circle_outlined,
    'incorporating' || 'waiting_to_incorporate' => Icons.sync_outlined,
    'complete' => Icons.check_circle_outline,
    'incorporated' => Icons.task_alt_outlined,
    'fail' || 'decline' || 'timeout' => Icons.error_outline,
    _ => Icons.hub_outlined,
  };

  Color _freeqStatusColor(String status) => switch (status) {
    'claimed' || 'accepted' => const Color(0xFF79C0FF),
    'incorporating' || 'waiting_to_incorporate' => const Color(0xFFD2A8FF),
    'complete' => const Color(0xFF7EE787),
    'incorporated' => const Color(0xFF7EE787),
    'fail' || 'decline' || 'timeout' => const Color(0xFFFF7B72),
    _ => const Color(0xFFE3B341),
  };

  bool _isFinishedFreeqHandoff(String status) => switch (status) {
    'complete' || 'incorporated' || 'fail' || 'decline' || 'timeout' => true,
    _ => false,
  };

  void _openExternalUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      return;
    }
    html.window.open(uri.toString(), '_blank');
  }

  Widget _externalLink(String value, {String? label}) => TextButton.icon(
    onPressed: () => _openExternalUrl(value),
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: Alignment.centerLeft,
    ),
    icon: const Icon(Icons.open_in_new, size: 13),
    label: Text(
      label ?? value,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(decoration: TextDecoration.underline),
    ),
  );

  Widget _messageText(String value) {
    final matches = RegExp(r'https?://[^\s<>()]+').allMatches(value).toList();
    if (matches.isEmpty) return SelectableText(value);

    final parts = <Widget>[];
    var offset = 0;
    for (final match in matches) {
      if (match.start > offset) {
        parts.add(Text(value.substring(offset, match.start)));
      }
      final url = match.group(0)!;
      final uri = Uri.tryParse(url);
      parts.add(
        _externalLink(
          url,
          label: uri?.host == 'agentgit.co'
              ? 'Open AgentGit exchange'
              : 'Open link',
        ),
      );
      offset = match.end;
    }
    if (offset < value.length) parts.add(Text(value.substring(offset)));
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: parts);
  }

  Widget _buildFreeqHandoffs() {
    final active = _freeqHandoffs
        .where(
          (handoff) => !_isFinishedFreeqHandoff(
            handoff['status']?.toString() ?? 'offered',
          ),
        )
        .toList();
    final finished = _freeqHandoffs
        .where(
          (handoff) => _isFinishedFreeqHandoff(
            handoff['status']?.toString() ?? 'offered',
          ),
        )
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('FREEQ', style: Theme.of(context).textTheme.labelSmall),
              if (active.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '${active.length} active',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
              const Spacer(),
              if (finished.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(
                    () => _showCompletedHandoffs = !_showCompletedHandoffs,
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  icon: Icon(
                    _showCompletedHandoffs
                        ? Icons.expand_less
                        : Icons.history_outlined,
                    size: 16,
                  ),
                  label: Text(
                    '${finished.length} completed',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          if (active.isNotEmpty) const SizedBox(height: 6),
          ...active.map((handoff) {
            final status = handoff['status']?.toString() ?? 'offered';
            final color = _freeqStatusColor(status);
            final title = handoff['title']?.toString() ?? 'FreeQ handoff';
            final botName =
                handoff['botName']?.toString() ?? 'Open channel offer';
            final note = handoff['note']?.toString().trim() ?? '';
            final exchangeUrl = handoff['exchangeUrl']?.toString() ?? '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B22),
                  border: Border.all(color: const Color(0xFF30363D)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_freeqStatusIcon(status), size: 16, color: color),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _freeqStatusLabel(status),
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status == 'offered'
                          ? 'Open offer in ${handoff['channel'] ?? 'FreeQ'}'
                          : 'Handled by $botName',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        status == 'incorporating'
                            ? 'Worker report (unverified): $note'
                            : note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (exchangeUrl.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      _externalLink(exchangeUrl, label: 'Open AgentGit review'),
                    ],
                  ],
                ),
              ),
            );
          }),
          if (_showCompletedHandoffs) ...[
            const SizedBox(height: 4),
            ...finished.map((handoff) {
              final status = handoff['status']?.toString() ?? 'complete';
              final color = _freeqStatusColor(status);
              final title = handoff['title']?.toString() ?? 'FreeQ handoff';
              final botName = handoff['botName']?.toString() ?? 'FreeQ bot';
              final exchangeUrl = handoff['exchangeUrl']?.toString() ?? '';
              final taskId = handoff['taskId']?.toString() ?? '';
              final canReview = status == 'complete' && taskId.isNotEmpty;
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_freeqStatusIcon(status), size: 14, color: color),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$title · $botName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (exchangeUrl.isNotEmpty)
                      _externalLink(exchangeUrl, label: 'Open AgentGit review'),
                    if (canReview)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _freeqReviewBusy.contains(taskId)
                              ? null
                              : () => _reviewFreeqHandoff(handoff),
                          icon: _freeqReviewBusy.contains(taskId)
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.rate_review_outlined,
                                  size: 16,
                                ),
                          label: const Text('Review & incorporate'),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
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
      await _refreshGitStatus();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _refreshGitStatus() async {
    if (_project == null) return;
    try {
      final response = await _request('GET', _projectUrl('/git/status'));
      if (mounted) setState(() => _gitStatus = GitStatus.fromJson(response));
    } catch (error) {
      if (mounted) setState(() => _gitStatus = null);
    }
  }

  Future<void> _showCurrentThreadDiff() async {
    if (_project?.isRepo != true || _diffBusy) return;
    setState(() => _diffBusy = true);
    try {
      final response = await _request('GET', _projectUrl('/git/diff'));
      if (!mounted) return;
      final diff = response['diff'] as String? ?? '';
      final branch = response['branch'] as String? ?? '';
      final truncated = response['truncated'] as bool? ?? false;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            branch.isEmpty
                ? 'Current work thread diff'
                : 'Current work thread diff — $branch',
          ),
          content: SizedBox(
            width: _dialogWidth(context, 900),
            height: _dialogHeight(context, 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (truncated)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('Diff is truncated at 2 MiB.'),
                  ),
                Expanded(
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      child: Text(
                        diff.isEmpty ? 'No changes in this work thread.' : diff,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _diffBusy = false);
    }
  }

  Future<void> _reviewFreeqHandoff(Map<String, dynamic> handoff) async {
    final project = _project;
    final taskId = handoff['taskId']?.toString() ?? '';
    if (project == null || taskId.isEmpty || _freeqReviewBusy.contains(taskId))
      return;
    setState(() => _freeqReviewBusy.add(taskId));
    try {
      final response = await _request(
        'GET',
        '/api/projects/${Uri.encodeComponent(project.name)}/freeq/handoffs/${Uri.encodeComponent(taskId)}/review',
      );
      if (!mounted) return;
      final diff = response['diff'] as String? ?? '';
      final truncated = response['truncated'] as bool? ?? false;
      final incorporate = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Review worker changes'),
          content: SizedBox(
            width: _dialogWidth(context, 900),
            height: _dialogHeight(context, 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This compares the worker branch against your current project. Applying it creates a merge commit.',
                ),
                if (truncated)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Diff is truncated at 2 MiB.'),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      child: Text(
                        diff.isEmpty
                            ? 'No changes in the worker branch.'
                            : diff,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: diff.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Incorporate changes'),
            ),
          ],
        ),
      );
      if (incorporate != true) return;
      await _request(
        'POST',
        '/api/projects/${Uri.encodeComponent(project.name)}/freeq/handoffs/${Uri.encodeComponent(taskId)}/incorporate',
      );
      if (!mounted) return;
      await Future.wait([_refreshGitStatus(), _refreshTree(), _loadSession()]);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _freeqReviewBusy.remove(taskId));
    }
  }

  Future<void> _commitChanges() async {
    final status = _gitStatus;
    if (status == null || status.changedCount == 0 || _gitBusy) return;
    if (!_codexConnected) {
      _showError('Connect Codex before creating a commit.');
      return;
    }
    String suggestedMessage;
    try {
      setState(() => _gitBusy = true);
      final suggestion = await _request(
        'POST',
        _projectUrl('/git/commit-message'),
      );
      suggestedMessage = suggestion['message'] as String? ?? '';
      if (suggestedMessage.isEmpty) {
        throw StateError('Codex returned an empty commit message');
      }
    } catch (error) {
      _showError(error);
      return;
    } finally {
      if (mounted) setState(() => _gitBusy = false);
    }
    _terminalInteractionEnabled.value = false;
    String? value;
    try {
      value = await showDialog<String>(
        context: context,
        builder: (context) => _CommitDialog(
          changedCount: status.changedCount,
          suggestedMessage: suggestedMessage,
        ),
      );
    } finally {
      _terminalInteractionEnabled.value = true;
    }
    if (value == null || value.isEmpty) return;
    await _runGitAction('/git/commit', {'message': value}, 'Commit created');
  }

  Future<void> _pushChanges() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Push branch?'),
        content: Text(
          'Push ${_gitStatus?.branch ?? 'this branch'} to its origin remote.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Push'),
          ),
        ],
      ),
    );
    if (confirmed == true)
      await _runGitAction('/git/push', null, 'Branch pushed');
  }

  Future<void> _createPullRequest() async {
    Map<String, dynamic> draft;
    try {
      draft = await _request('GET', _projectUrl('/git/draft/pull-request'));
    } catch (error) {
      _showError(error);
      return;
    }
    final title = TextEditingController(text: draft['title'] as String? ?? '');
    final base = TextEditingController(text: draft['base'] as String? ?? '');
    final description = TextEditingController(
      text: draft['description'] as String? ?? '',
    );
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create pull request'),
        content: SizedBox(
          width: _dialogWidth(context, 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: base,
                decoration: const InputDecoration(labelText: 'Base branch'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: description,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: 'Description'),
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
            onPressed: () => Navigator.pop(context, [
              title.text.trim(),
              base.text.trim(),
              description.text.trim(),
            ]),
            child: const Text('Create PR'),
          ),
        ],
      ),
    );
    title.dispose();
    base.dispose();
    description.dispose();
    if (values == null || values.any((value) => value.isEmpty)) return;
    final autoMergeMethod = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Merge after checks pass?'),
        content: const Text(
          'Enable GitHub auto-merge now, or create the pull request without it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Create PR only'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'merge'),
            child: const Text('Auto: merge commit'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'rebase'),
            child: const Text('Auto: rebase'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'squash'),
            child: const Text('Auto: squash'),
          ),
        ],
      ),
    );
    if (autoMergeMethod == null) return;
    await _runGitAction(
      '/git/pull-request',
      {
        'title': values[0],
        'base': values[1],
        'description': values[2],
        'autoMergeMethod': autoMergeMethod,
      },
      autoMergeMethod.isEmpty
          ? 'Pull request created'
          : 'Pull request created with auto-merge',
    );
  }

  Future<void> _enableAutoMerge() async {
    final method = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable auto-merge'),
        content: const Text(
          'GitHub will merge this branch only after all required checks and branch protections pass. Choose the merge method.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'merge'),
            child: const Text('Create merge commit'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'rebase'),
            child: const Text('Rebase'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'squash'),
            child: const Text('Squash'),
          ),
        ],
      ),
    );
    if (method == null) return;
    await _runGitAction('/git/pull-request/auto-merge', {
      'method': method,
    }, 'Auto-merge enabled');
  }

  Future<void> _runGitAction(
    String endpoint,
    Map<String, dynamic>? body,
    String success,
  ) async {
    if (_project == null || _gitBusy) return;
    setState(() => _gitBusy = true);
    try {
      final response = await _request('POST', _projectUrl(endpoint), body);
      await _refreshGitStatus();
      if (response['url'] is String && mounted) {
        _showError('$success: ${response['url']}');
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _gitBusy = false);
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
          width: _dialogWidth(context, 480),
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

  Future<void> _createWorktree() async {
    final project = _project;
    if (project == null || !project.isRepo || _gitBusy) return;
    final workspace = TextEditingController(text: '${project.name}-worktree');
    final branch = TextEditingController();
    final startPoint = TextEditingController(text: project.branch);
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create isolated worktree'),
        content: SizedBox(
          width: _dialogWidth(context, 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'A worktree has its own checkout and new branch, so Codex can work without changing this workspace.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: workspace,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Workspace name',
                  hintText: 'feature-worktree',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: branch,
                decoration: const InputDecoration(
                  labelText: 'New branch name',
                  hintText: 'codex/new-feature',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: startPoint,
                decoration: const InputDecoration(
                  labelText: 'Starting ref',
                  hintText: 'main or a commit SHA',
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
            onPressed: () => Navigator.pop(context, [
              workspace.text.trim(),
              branch.text.trim(),
              startPoint.text.trim(),
            ]),
            child: const Text('Create worktree'),
          ),
        ],
      ),
    );
    workspace.dispose();
    branch.dispose();
    startPoint.dispose();
    if (values == null || values.any((value) => value.isEmpty)) return;
    setState(() => _gitBusy = true);
    try {
      final response = await _request('POST', _projectUrl('/worktrees'), {
        'workspaceName': values[0],
        'branch': values[1],
        'startPoint': values[2],
      });
      await _refreshProjects(select: response['name'] as String);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _gitBusy = false);
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
    if (_runningWorkThreads.isNotEmpty) {
      _showError('Stop running work threads before closing the project.');
      return;
    }
    if (_dirty && !await _confirmDiscard()) return;
    final project = _project!;
    for (final terminal in _terminals) {
      unawaited(_closeTerminal(project.name, terminal.id));
    }
    _terminals.clear();
    _activeTerminalId = null;
    _terminalVisible = false;
    _code.clear();
    _forgetLastProject();
    setState(() {
      _project = null;
      _path = null;
      _savedText = '';
      _files = const [];
      _messages = const [];
      _workThreads = const [];
      _activeWorkThreadId = null;
      _threadHistory = const [];
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

  void _updateWorkThreadMessages(
    String threadId,
    List<AgentMessage> messages, {
    String? title,
  }) {
    _workThreads = _workThreads
        .map(
          (thread) => thread.id == threadId
              ? thread.withMessages(messages, newTitle: title)
              : thread,
        )
        .toList();
  }

  Future<void> _selectWorkThread(String threadId) async {
    if (_activeWorkThreadId == threadId || _project == null) return;
    final thread = _workThreads.where((item) => item.id == threadId).firstOrNull;
    if (thread == null) return;
    setState(() {
      _activeWorkThreadId = threadId;
      _messages = thread.messages;
      _agentBusy = _runningWorkThreads.contains(threadId);
      _agentStopping = _stoppingWorkThreads.contains(threadId);
      _agentActivity = _workThreadActivity[threadId] ?? const [];
      _streamedResponse = _workThreadStreams[threadId] ?? '';
    });
    _scrollMessages();
    try {
      await _request('PATCH', _projectUrl('/session'), {'threadId': threadId});
    } catch (error) {
      _showError(error);
    }
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
    final workThreadId = _activeWorkThreadId;
    if (workThreadId == null) return;
    setState(() {
      _runningWorkThreads.add(workThreadId);
      _agentBusy = true;
      _agentPrompt.clear();
      _messages = [..._messages, AgentMessage(role: 'user', text: prompt)];
      _agentActivity = const ['Starting Codex…'];
      _streamedResponse = '';
      _workThreadActivity[workThreadId] = _agentActivity;
      _workThreadStreams[workThreadId] = '';
      final currentThread = _workThreads
          .where((thread) => thread.id == workThreadId)
          .firstOrNull;
      _updateWorkThreadMessages(
        workThreadId,
        _messages,
        title: currentThread?.title.startsWith('Work thread ') == true
            ? (prompt.length <= 48 ? prompt : prompt.substring(0, 48))
            : null,
      );
      _error = null;
    });
    _scrollMessages();
    try {
      final started = await _request('POST', _projectUrl('/agent'), {
        'prompt': prompt,
        'threadId': workThreadId,
      });
      final runId = started['runId'] as String?;
      if (runId == null || runId.isEmpty) {
        throw StateError('Agent run did not start.');
      }
      final completed = Completer<void>();
      final source = html.EventSource('${_projectUrl('/agent/events')}/$runId');
      _agentEventSources[workThreadId] = source;
      source.onMessage.listen((event) {
        final value = jsonDecode(event.data as String) as Map<String, dynamic>;
        final type = value['type'] as String?;
        if (!mounted) return;
        if (type == 'activity') {
          final activity = value['text']?.toString() ?? '';
          if (activity.isNotEmpty) {
            setState(() {
              final previous = _workThreadActivity[workThreadId] ?? const [];
              final next = [...previous, activity];
              final values = next.length > 12
                  ? next.sublist(next.length - 12)
                  : next;
              _workThreadActivity[workThreadId] = values;
              if (_activeWorkThreadId == workThreadId) _agentActivity = values;
            });
            _scrollMessages();
          }
        } else if (type == 'response_delta') {
          setState(() {
            final stream = (_workThreadStreams[workThreadId] ?? '') +
                (value['text']?.toString() ?? '');
            _workThreadStreams[workThreadId] = stream;
            if (_activeWorkThreadId == workThreadId) _streamedResponse = stream;
          });
          _scrollMessages();
        } else if (type == 'complete') {
          final messages = value['messages'];
          setState(() {
            List<AgentMessage>? completedMessages;
            if (messages is List<dynamic>) {
              completedMessages = messages
                  .map(
                    (item) =>
                        AgentMessage.fromJson(item as Map<String, dynamic>),
                  )
                  .toList();
            } else if ((_workThreadStreams[workThreadId] ?? '').isEmpty) {
              final existing =
                  _workThreads
                      .where((thread) => thread.id == workThreadId)
                      .firstOrNull
                      ?.messages ??
                  const [];
              completedMessages = [
                ...existing,
                AgentMessage(
                  role: 'assistant',
                  text: value['response']?.toString() ?? 'Stopped.',
                ),
              ];
            }
            if (completedMessages != null) {
              _updateWorkThreadMessages(workThreadId, completedMessages);
              if (_activeWorkThreadId == workThreadId) {
                _messages = completedMessages;
              }
            }
          });
          source.close();
          if (!completed.isCompleted) completed.complete();
        } else if (type == 'error') {
          source.close();
          if (!completed.isCompleted) {
            completed.completeError(
              StateError(value['error']?.toString() ?? 'Agent turn failed.'),
            );
          }
        }
      });
      source.onError.listen((_) {
        if (!completed.isCompleted) {
          completed.completeError(
            StateError('Agent progress connection closed.'),
          );
        }
      });
      await completed.future;
      _agentEventSources.remove(workThreadId);
      if (!mounted) return;
      await _refreshTree();
      if (_path != null) await _openFile(_path!);
      await _refreshGitStatus();
      _scrollMessages();
    } catch (error) {
      _showError(error);
    } finally {
      _agentEventSources.remove(workThreadId)?.close();
      if (mounted) {
        setState(() {
          _runningWorkThreads.remove(workThreadId);
          _stoppingWorkThreads.remove(workThreadId);
          _workThreadActivity.remove(workThreadId);
          _workThreadStreams.remove(workThreadId);
          if (_activeWorkThreadId == workThreadId) {
            _agentBusy = false;
            _agentStopping = false;
            _agentActivity = const [];
            _streamedResponse = '';
          }
        });
        _scrollMessages();
      }
    }
  }

  Future<void> _stopAgent() async {
    if (_project == null || !_agentBusy || _agentStopping) return;
    setState(() {
      if (_activeWorkThreadId != null) {
        _stoppingWorkThreads.add(_activeWorkThreadId!);
      }
      _agentStopping = true;
      _error = null;
    });
    try {
      await _request('POST', _projectUrl('/agent/stop'), {
        'threadId': _activeWorkThreadId,
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          if (_activeWorkThreadId != null) {
            _stoppingWorkThreads.remove(_activeWorkThreadId!);
          }
          _agentStopping = false;
        });
      }
      _showError(error);
    }
  }

  Future<void> _resetAgent() async {
    if (_project == null) return;
    final name = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create another work thread'),
        content: SizedBox(
          width: _dialogWidth(context, 420),
          child: TextField(
            controller: name,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: 'Work thread name',
              hintText: 'Add search to the projects page',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = name.text.trim();
              if (trimmed.isNotEmpty) {
                Navigator.pop(context, trimmed);
              }
            },
            child: const Text('Create thread'),
          ),
        ],
      ),
    );
    name.dispose();
    if (result == null) return;
    try {
      await _request('DELETE', _projectUrl('/session'), {
        'name': result,
      });
      await _loadSession();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _archiveWorkThread(AgentWorkThread thread) async {
    if (_project == null || _runningWorkThreads.contains(thread.id)) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Archive work thread?'),
            content: Text(
              'Move “${thread.title}” to Previous work threads?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.archive_outlined),
                label: const Text('Archive'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await _request(
        'DELETE',
        _projectUrl('/session/${Uri.encodeComponent(thread.id)}'),
      );
      _workThreadActivity.remove(thread.id);
      _workThreadStreams.remove(thread.id);
      await _loadSession();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _showThreadHistory() async {
    if (_project == null) return;
    await _loadSession();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Previous work threads'),
        content: SizedBox(
          width: _dialogWidth(context, 520),
          child: _threadHistory.isEmpty
              ? const Text('No previous threads for this project yet.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: _threadHistory.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final thread = _threadHistory[index];
                    final timestamp = DateTime.tryParse(
                      thread.archivedAt ?? '',
                    );
                    final date = timestamp == null
                        ? 'Saved work thread'
                        : 'Saved ${timestamp.toLocal().toString().substring(0, 16)}';
                    return ListTile(
                      title: Text(
                        thread.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '$date · ${thread.messages.length} messages',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final reactivate = await _showHistoricalThread(thread);
                        if (!reactivate || !context.mounted) return;
                        Navigator.pop(context);
                        await _reactivateHistoricalThread(thread);
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _reactivateHistoricalThread(
    AgentThreadHistory thread,
  ) async {
    if (_project == null || thread.archivedAt == null) return;
    try {
      await _request('POST', _projectUrl('/session/reactivate'), {
        'archivedAt': thread.archivedAt,
      });
      await _loadSession();
    } catch (error) {
      _showError(error);
    }
  }

  Future<bool> _showHistoricalThread(
    AgentThreadHistory thread,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            thread.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: _dialogWidth(context, 560),
            height: _dialogHeight(context, 480),
            child: ListView.separated(
              itemCount: thread.messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final message = thread.messages[index];
                final user = message.role == 'user';
                return Align(
                  alignment: user
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: user
                          ? const Color(0xFF263659)
                          : const Color(0xFF161B22),
                      border: Border.all(color: const Color(0xFF30363D)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _messageText(message.text),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back'),
            ),
            FilledButton.icon(
              onPressed: thread.archivedAt == null
                  ? null
                  : () => Navigator.pop(context, true),
              icon: const Icon(Icons.unarchive_outlined),
              label: const Text('Reactivate'),
            ),
          ],
        ),
      ) ??
      false;

  void _openTerminal() {
    final project = _project;
    if (project == null) return;
    final showAsDialog = MediaQuery.sizeOf(context).width < 900;
    setState(() {
      if (_terminals.isEmpty) {
        _terminals.add(TerminalSession(_nextTerminalId++));
      }
      _activeTerminalId ??= _terminals.last.id;
      if (!showAsDialog) _terminalVisible = !_terminalVisible;
    });
    if (!showAsDialog) return;
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
                                        if (_terminals.length == 1) {
                                          _terminals.remove(terminal);
                                          _activeTerminalId = null;
                                          unawaited(
                                            _closeTerminal(
                                              project.name,
                                              terminal.id,
                                            ),
                                          );
                                          Navigator.pop(context);
                                          return;
                                        }
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
                                        unawaited(
                                          _closeTerminal(
                                            project.name,
                                            terminal.id,
                                          ),
                                        );
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

  void _newTerminal() => setState(() {
    final terminal = TerminalSession(_nextTerminalId++);
    _terminals.add(terminal);
    _activeTerminalId = terminal.id;
  });

  void _closeTerminalTab(TerminalSession terminal) {
    final project = _project;
    if (project == null) return;
    setState(() {
      final closedIndex = _terminals.indexOf(terminal);
      _terminals.remove(terminal);
      if (_activeTerminalId == terminal.id) {
        _activeTerminalId = _terminals.isEmpty
            ? null
            : _terminals[closedIndex.clamp(0, _terminals.length - 1).toInt()]
                  .id;
      }
      if (_terminals.isEmpty) _terminalVisible = false;
    });
    unawaited(_closeTerminal(project.name, terminal.id));
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
      if (!mounted || !_messagesScroll.hasClients) return;
      _messagesScroll.jumpTo(_messagesScroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _loginEvents?.close();
    for (final source in _agentEventSources.values) {
      source.close();
    }
    _freeqPoller?.cancel();
    _highlightTimer?.cancel();
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

  PreferredSizeWidget _buildAppBar() {
    final project = _project;
    final projectLabel = project == null
        ? 'Codex Workspace'
        : project.repoUrl.isEmpty
        ? project.name
        : project.repoUrl;

    if (MediaQuery.sizeOf(context).width < 1100) {
      return _buildMobileAppBar(project);
    }

    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 22),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              project == null
                  ? projectLabel
                  : 'Codex Workspace — $projectLabel',
              overflow: TextOverflow.ellipsis,
            ),
          ),
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
        Tooltip(
          message: _deployedVersion,
          child: Chip(
            avatar: const Icon(Icons.code, size: 16),
            label: Text('Release ${_deployedVersion.substring(0, 12)}'),
          ),
        ),
        TextButton.icon(
          onPressed: _project == null ? null : _openTerminal,
          icon: const Icon(Icons.terminal),
          label: Text(_terminalVisible ? 'Hide terminal' : 'Terminal'),
        ),
        TextButton.icon(
          onPressed: _createProject,
          icon: const Icon(Icons.add),
          label: const Text('Project'),
        ),
        if (project != null)
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
          tooltip: _userName.isEmpty ? 'AT Protocol account' : _userName,
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
  }

  PreferredSizeWidget _buildMobileAppBar(ProjectSummary? project) => AppBar(
    titleSpacing: 12,
    title: Row(
      children: [
        const Icon(Icons.auto_awesome, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: _projects.isEmpty
              ? Text(
                  project?.name ?? 'Codex Workspace',
                  overflow: TextOverflow.ellipsis,
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<ProjectSummary>(
                    value: project,
                    isExpanded: true,
                    hint: const Text('Select project'),
                    items: _projects
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(
                              item.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) _selectProject(value);
                    },
                  ),
                ),
        ),
      ],
    ),
    actions: [
      IconButton(
        tooltip: _terminalVisible ? 'Hide terminal' : 'Show terminal',
        onPressed: project == null ? null : _openTerminal,
        icon: const Icon(Icons.terminal),
      ),
      PopupMenuButton<String>(
        tooltip: 'Workspace actions',
        onSelected: (value) {
          if (value == 'create') _createProject();
          if (value == 'connect') _connectCodex();
          if (value == 'rename') _renameProject();
          if (value == 'close') _closeProject();
          if (value == 'logout') _logout();
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'create',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.add),
              title: Text('Add project'),
            ),
          ),
          if (!_codexConnected)
            const PopupMenuItem(
              value: 'connect',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.link),
                title: Text('Connect Codex'),
              ),
            ),
          if (project != null) ...[
            const PopupMenuItem(
              value: 'rename',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.drive_file_rename_outline),
                title: Text('Rename project'),
              ),
            ),
            const PopupMenuItem(
              value: 'close',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.close),
                title: Text('Close project'),
              ),
            ),
          ],
          PopupMenuItem<String>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text(_userInitial)),
              title: Text(_userName.isEmpty ? 'Account' : _userName),
              subtitle: _userEmail.isEmpty ? null : Text(_userEmail),
            ),
          ),
          const PopupMenuItem(
            value: 'logout',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout),
              title: Text('Log out'),
            ),
          ),
        ],
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
          padding: EdgeInsets.all(_isMobile ? 20 : 32),
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
      final maxTerminalHeight = (constraints.maxHeight - 180)
          .clamp(160, 640)
          .toDouble();
      final terminalHeight = _terminalHeight
          .clamp(160, maxTerminalHeight)
          .toDouble();
      if (constraints.maxWidth < 900) {
        return DefaultTabController(
          length: 3,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(icon: Icon(Icons.folder_outlined), text: 'Files'),
                  Tab(icon: Icon(Icons.edit_outlined), text: 'Editor'),
                  Tab(icon: Icon(Icons.auto_awesome_outlined), text: 'Agent'),
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
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 250, child: _buildFiles()),
                const VerticalDivider(width: 1),
                Expanded(child: _buildEditor()),
                const VerticalDivider(width: 1),
                SizedBox(width: 390, child: _buildAgent()),
              ],
            ),
          ),
          if (_terminalVisible && _terminals.isNotEmpty) ...[
            MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) => setState(() {
                  _terminalHeight = (_terminalHeight - details.delta.dy)
                      .clamp(160, maxTerminalHeight)
                      .toDouble();
                }),
                child: const SizedBox(height: 6, child: Divider(height: 1)),
              ),
            ),
            SizedBox(height: terminalHeight, child: _buildTerminalPanel()),
          ],
        ],
      );
    },
  );

  Widget _buildTerminalPanel() {
    final project = _project;
    final terminal = _terminals.isEmpty
        ? null
        : _terminals.firstWhere(
            (terminal) => terminal.id == _activeTerminalId,
            orElse: () => _terminals.last,
          );
    if (project == null || terminal == null) return const SizedBox.shrink();
    return Column(
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
          ),
          child: Row(
            children: [
              Text('TERMINAL', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(width: 12),
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: _terminals
                      .map(
                        (tab) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  setState(() => _activeTerminalId = tab.id),
                              style: TextButton.styleFrom(
                                foregroundColor: _activeTerminalId == tab.id
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              child: Text(tab.label),
                            ),
                            IconButton(
                              tooltip: 'Close ${tab.label}',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              onPressed: () => _closeTerminalTab(tab),
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
                visualDensity: VisualDensity.compact,
                onPressed: _newTerminal,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: GhosttyTerminal(
            projectName: project.name,
            sessionId: terminal.id,
          ),
        ),
      ],
    );
  }

  Widget _panelHeader(String title, List<Widget> actions) => Container(
    constraints: const BoxConstraints(minHeight: 48),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
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
                        dense: !_isMobile,
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
                            : () {
                                unawaited(_openFile(node.path));
                                if (_isMobile) {
                                  DefaultTabController.of(context).animateTo(1);
                                }
                              },
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
                padding: EdgeInsets.all(_isMobile ? 10 : 16),
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
      _panelHeader(
        _runningWorkThreads.isEmpty
            ? 'AGENT'
            : 'AGENT · ${_runningWorkThreads.length} RUNNING',
        _buildAgentHeaderActions(),
      ),
      _buildAgentTabs(),
      if (_agentPanelTab == _AgentPanelTab.chat) _buildWorkThreadSwitcher(),
      Expanded(
        child: switch (_agentPanelTab) {
          _AgentPanelTab.chat => _buildAgentConversation(),
          _AgentPanelTab.sourceControl =>
            _gitStatus?.isRepo == true
                ? _buildSourceControl()
                : const Center(child: Text('Source control is not available')),
          _AgentPanelTab.freeq => _buildFreeqHandoffs(),
        },
      ),
    ],
  );

  List<Widget> _buildAgentHeaderActions() {
    if (_isMobile) {
      return [
        if (_agentBusy)
          IconButton(
            tooltip: _agentStopping ? 'Stopping agent' : 'Stop agent',
            onPressed: _agentStopping ? null : _stopAgent,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        IconButton(
          tooltip: 'New thread',
          onPressed: _resetAgent,
          icon: const Icon(Icons.add_comment_outlined),
        ),
        PopupMenuButton<String>(
          tooltip: 'Agent actions',
          onSelected: (value) {
            if (value == 'handoff') _openFreeqHandoff();
            if (value == 'worktree') _createWorktree();
            if (value == 'refresh') _refreshGitStatus();
            if (value == 'diff') _showCurrentThreadDiff();
            if (value == 'history') _showThreadHistory();
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'handoff',
              enabled: !_agentBusy,
              child: const Text('Hand off to FreeQ'),
            ),
            if (_project?.isRepo == true) ...[
              PopupMenuItem(
                value: 'worktree',
                enabled: !_gitBusy,
                child: const Text('Create worktree'),
              ),
              PopupMenuItem(
                value: 'refresh',
                enabled: !_gitBusy,
                child: const Text('Refresh source control'),
              ),
              PopupMenuItem(
                value: 'diff',
                enabled: !_diffBusy,
                child: const Text('Show current diff'),
              ),
            ],
            PopupMenuItem(
              value: 'history',
              enabled: !_agentBusy,
              child: const Text('Previous threads'),
            ),
          ],
        ),
      ];
    }
    return [
      IconButton(
        tooltip: 'Hand off to a FreeQ bot',
        visualDensity: VisualDensity.compact,
        onPressed: _agentBusy ? null : _openFreeqHandoff,
        icon: const Icon(Icons.hub_outlined, size: 18),
      ),
      IconButton(
        tooltip: 'Create isolated Git worktree',
        visualDensity: VisualDensity.compact,
        onPressed: _project?.isRepo == true && !_gitBusy
            ? _createWorktree
            : null,
        icon: const Icon(Icons.account_tree_outlined, size: 18),
      ),
      IconButton(
        tooltip: 'Refresh source control',
        visualDensity: VisualDensity.compact,
        onPressed: _project?.isRepo == true && !_gitBusy
            ? _refreshGitStatus
            : null,
        icon: const Icon(Icons.sync_outlined, size: 18),
      ),
      IconButton(
        tooltip: 'Show diff for current work thread',
        visualDensity: VisualDensity.compact,
        onPressed: _project?.isRepo == true && !_diffBusy
            ? _showCurrentThreadDiff
            : null,
        icon: _diffBusy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.difference_outlined, size: 18),
      ),
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
      IconButton(
        tooltip: 'Show previous work threads',
        visualDensity: VisualDensity.compact,
        onPressed: _agentBusy ? null : _showThreadHistory,
        icon: const Icon(Icons.history_outlined, size: 18),
      ),
    ];
  }

  Widget _buildAgentTabs() {
    final tabs = <(_AgentPanelTab, String, IconData)>[
      (_AgentPanelTab.chat, 'Chat', Icons.forum_outlined),
      if (_gitStatus?.isRepo == true)
        (
          _AgentPanelTab.sourceControl,
          'Source Control',
          Icons.account_tree_outlined,
        ),
      (_AgentPanelTab.freeq, 'FreeQ', Icons.hub_outlined),
    ];
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Row(
        children: tabs.map((tab) {
          final selected = _agentPanelTab == tab.$1;
          return Expanded(
            child: Semantics(
              button: true,
              selected: selected,
              label: '${tab.$2} tab',
              child: TextButton.icon(
                onPressed: () {
                  setState(() => _agentPanelTab = tab.$1);
                  if (tab.$1 == _AgentPanelTab.chat) _scrollMessages();
                },
                icon: Icon(tab.$3, size: 16),
                label: Text(tab.$2, overflow: TextOverflow.ellipsis),
                style: TextButton.styleFrom(
                  foregroundColor: selected
                      ? const Color(0xFFB6C8FF)
                      : const Color(0xFF8B949E),
                  backgroundColor: selected
                      ? const Color(0xFF1F2A44)
                      : Colors.transparent,
                  shape: const RoundedRectangleBorder(),
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 4,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildWorkThreadSwitcher() => Container(
    height: 46,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: const BoxDecoration(
      color: Color(0xFF0D1117),
      border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
    ),
    child: Row(
      children: [
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _workThreads.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final thread = _workThreads[index];
              final selected = thread.id == _activeWorkThreadId;
              final running = _runningWorkThreads.contains(thread.id);
              return Tooltip(
                message: thread.title,
                child: InputChip(
                  selected: selected,
                  onSelected: (_) => _selectWorkThread(thread.id),
                  onDeleted: running ? null : () => _archiveWorkThread(thread),
                  deleteIcon: const Icon(Icons.archive_outlined, size: 16),
                  deleteButtonTooltipMessage: running
                      ? 'Stop this thread before archiving it'
                      : 'Archive ${thread.title}',
                  avatar: running
                      ? const SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          thread.messages.isEmpty
                              ? Icons.chat_bubble_outline
                              : Icons.chat_bubble,
                          size: 14,
                        ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Text(
                      thread.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'New parallel work thread',
          visualDensity: VisualDensity.compact,
          onPressed: _resetAgent,
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    ),
  );

  Widget _buildAgentConversation() => Column(
    children: [
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text(
                                _agentStopping
                                    ? 'Stopping Codex…'
                                    : 'Codex is working…',
                              ),
                            ],
                          ),
                          if (_agentActivity.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF161B22),
                                border: Border.all(
                                  color: const Color(0xFF30363D),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: _agentActivity
                                    .map(
                                      (activity) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 4,
                                        ),
                                        child: Text('• $activity'),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ],
                          if (_streamedResponse.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF161B22),
                                border: Border.all(
                                  color: const Color(0xFF30363D),
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: _messageText(_streamedResponse),
                            ),
                          ],
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
                      child: _messageText(message.text),
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
                  decoration: InputDecoration(
                    hintText: 'Ask Codex to change this project…',
                    helperText: _isMobile ? null : 'Ctrl/Cmd+Enter to run',
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

  Widget _buildSourceControl() {
    final status = _gitStatus!;
    final primary = status.changedCount > 0
        ? _commitChanges
        : status.ahead > 0
        ? _pushChanges
        : null;
    final primaryLabel = status.changedCount > 0
        ? 'Commit ${status.changedCount} ${status.changedCount == 1 ? 'change' : 'changes'}'
        : status.ahead > 0
        ? 'Push ${status.ahead} ${status.ahead == 1 ? 'commit' : 'commits'}'
        : 'Up to date';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'SOURCE CONTROL',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      status.branch.isEmpty
                          ? 'Detached HEAD'
                          : 'Branch: ${status.branch}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ],
                ),
              ),
              if (status.behind > 0)
                Text(
                  '↓${status.behind}',
                  style: const TextStyle(color: Color(0xFFE3B341)),
                ),
              if (status.ahead > 0)
                Text(
                  ' ↑${status.ahead}',
                  style: const TextStyle(color: Color(0xFF7EE787)),
                ),
            ],
          ),
        ),
        Expanded(
          child: status.files.isEmpty
              ? const Center(child: Text('No uncommitted changes'))
              : ListView.builder(
                  itemCount: status.files.length,
                  itemBuilder: (context, index) {
                    final change = status.files[index];
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Text(
                        change.label.substring(0, 1),
                        style: const TextStyle(color: Color(0xFFE3B341)),
                      ),
                      title: Text(
                        change.path,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Text(
                        change.label,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _gitBusy ? null : primary,
                  icon: Icon(
                    status.changedCount > 0
                        ? Icons.commit
                        : Icons.cloud_upload_outlined,
                    size: 17,
                  ),
                  label: Text(primaryLabel),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Create a pull request after pushing this branch',
                onPressed:
                    _gitBusy ||
                        !status.hasRemote ||
                        !status.prAvailable ||
                        status.changedCount > 0 ||
                        status.ahead == 0
                    ? null
                    : _createPullRequest,
                icon: const Icon(Icons.call_merge_outlined, size: 19),
              ),
              IconButton(
                tooltip: 'Enable auto-merge for this branch\'s pull request',
                onPressed:
                    _gitBusy ||
                        !status.hasRemote ||
                        !status.prAvailable ||
                        status.changedCount > 0
                    ? null
                    : _enableAutoMerge,
                icon: const Icon(Icons.merge_type_outlined, size: 19),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class SaveIntent extends Intent {
  const SaveIntent();
}

class RunAgentIntent extends Intent {
  const RunAgentIntent();
}
