import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const CloudCodeEditor());

class CloudCodeEditor extends StatelessWidget {
  const CloudCodeEditor({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cloud Code Editor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xFF17191F),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF86A9FF),
            brightness: Brightness.dark,
          ),
        ),
        home: const EditorScreen(),
      );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _path = TextEditingController(text: Directory.current.path);
  final _code = TextEditingController();
  final _focus = FocusNode();
  String? _filePath;
  String _savedText = '';
  String? _error;
  bool _busy = false;
  List<FileSystemEntity> _entries = [];

  bool get _dirty => _code.text != _savedText;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onEdit);
    _openDirectory();
  }

  void _onEdit() => setState(() {});

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
            ],
          ),
        ) ?? false;
  }

  Future<void> _openDirectory() async {
    final directory = Directory(_path.text.trim());
    setState(() { _busy = true; _error = null; });
    try {
      final entries = await directory.list(followLinks: false).toList();
      entries.sort((a, b) {
        final type = (b is Directory ? 1 : 0) - (a is Directory ? 1 : 0);
        return type != 0 ? type : a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (!mounted) return;
      setState(() { _path.text = directory.absolute.path; _entries = entries; });
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openFile(File file) async {
    if (!await _confirmDiscard()) return;
    setState(() { _busy = true; _error = null; });
    try {
      final content = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _filePath = file.path;
        _savedText = content;
        _code.value = TextEditingValue(text: content);
      });
      _focus.requestFocus();
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FormatException {
      if (mounted) setState(() => _error = 'This file is not UTF-8 text.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final path = _filePath;
    if (path == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final snapshot = _code.text;
      await File(path).writeAsString(snapshot);
      if (mounted) setState(() => _savedText = snapshot);
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _code.removeListener(_onEdit);
    _code.dispose();
    _path.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
          SingleActivator(LogicalKeyboardKey.keyS, meta: true): SaveIntent()},
        child: Actions(
          actions: {SaveIntent: CallbackAction<SaveIntent>(onInvoke: (_) { _save(); return null; })},
          child: Scaffold(
            appBar: AppBar(
              title: Text(_filePath == null ? 'Cloud Code Editor' : '${_filePath!.split(Platform.pathSeparator).last}${_dirty ? ' •' : ''}'),
              actions: [IconButton(tooltip: 'Save (Ctrl/Cmd+S)', onPressed: _filePath == null || !_dirty || _busy ? null : _save, icon: const Icon(Icons.save_outlined))],
            ),
            body: Row(children: [
              SizedBox(width: 280, child: Column(children: [
                Padding(padding: const EdgeInsets.all(8), child: TextField(
                  controller: _path,
                  decoration: InputDecoration(labelText: 'Local folder', suffixIcon: IconButton(onPressed: _openDirectory, icon: const Icon(Icons.arrow_forward))),
                  onSubmitted: (_) => _openDirectory(),
                )),
                Expanded(child: ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entity = _entries[index];
                    final isDir = entity is Directory;
                    return ListTile(
                      dense: true,
                      leading: Icon(isDir ? Icons.folder_outlined : Icons.description_outlined, size: 19),
                      title: Text(entity.path.split(Platform.pathSeparator).last, overflow: TextOverflow.ellipsis),
                      onTap: () async {
                        if (isDir) {
                          if (!await _confirmDiscard()) return;
                          _path.text = entity.path;
                          await _openDirectory();
                        } else if (entity is File) {
                          await _openFile(entity);
                        }
                      },
                    );
                  },
                )),
              ])),
              const VerticalDivider(width: 1),
              Expanded(child: Column(children: [
                if (_error != null) MaterialBanner(content: Text(_error!), actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text('Dismiss'))]),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: _filePath == null
                    ? const Center(child: Text('Choose a text file to start editing.'))
                    : Padding(padding: const EdgeInsets.all(16), child: TextField(
                        focusNode: _focus,
                        controller: _code,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5),
                        decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.zero),
                      ))),
                if (_filePath != null) Padding(padding: const EdgeInsets.all(8), child: Text(_filePath!, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ])),
            ]),
          ),
        ),
      );
}

class SaveIntent extends Intent {
  const SaveIntent();
}
