import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const WebEditor());

class WebEditor extends StatelessWidget {
  const WebEditor({super.key});

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
    home: const WebEditorScreen(),
  );
}

class WebEditorScreen extends StatefulWidget {
  const WebEditorScreen({super.key});

  @override
  State<WebEditorScreen> createState() => _WebEditorScreenState();
}

class _WebEditorScreenState extends State<WebEditorScreen> {
  final _code = TextEditingController();
  final _focus = FocusNode();
  String? _name;
  String _savedText = '';
  String? _error;

  bool get _dirty => _code.text != _savedText;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onEdit);
  }

  void _onEdit() => setState(() {});

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
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

  Future<void> _open() async {
    if (!await _confirmDiscard()) return;
    final input = html.FileUploadInputElement()
      ..accept =
          'text/*,.dart,.js,.ts,.json,.md,.yaml,.yml,.py,.rs,.go,.zig,.html,.css';
    input.click();
    await input.onChange.first;
    final file = input.files?.firstOrNull;
    if (file == null) return;
    try {
      final reader = html.FileReader();
      reader.readAsText(file);
      await reader.onLoadEnd.first;
      if (reader.error != null) throw Exception(reader.error.toString());
      final content = reader.result as String;
      if (!mounted) return;
      setState(() {
        _name = file.name;
        _savedText = content;
        _code.value = TextEditingValue(text: content);
        _error = null;
      });
      _focus.requestFocus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read file: $e');
    }
  }

  void _save() {
    if (_name == null) return;
    final snapshot = _code.text;
    final blob = html.Blob([snapshot], 'text/plain;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final link = html.AnchorElement(href: url)
      ..download = _name
      ..style.display = 'none';
    html.document.body?.append(link);
    link.click();
    link.remove();
    // Give the browser time to start the download before releasing the URL.
    Future<void>.delayed(
      const Duration(seconds: 1),
      () => html.Url.revokeObjectUrl(url),
    );
    setState(() => _savedText = snapshot);
  }

  @override
  void dispose() {
    _code.removeListener(_onEdit);
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.keyS, control: true): SaveIntent(),
      SingleActivator(LogicalKeyboardKey.keyS, meta: true): SaveIntent(),
      SingleActivator(LogicalKeyboardKey.keyO, control: true): OpenIntent(),
      SingleActivator(LogicalKeyboardKey.keyO, meta: true): OpenIntent(),
    },
    child: Actions(
      actions: {
        SaveIntent: CallbackAction<SaveIntent>(
          onInvoke: (_) {
            _save();
            return null;
          },
        ),
        OpenIntent: CallbackAction<OpenIntent>(
          onInvoke: (_) {
            _open();
            return null;
          },
        ),
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _name == null ? 'Cloud Code Editor' : '$_name${_dirty ? ' •' : ''}',
          ),
          actions: [
            IconButton(
              tooltip: 'Open file (Ctrl/Cmd+O)',
              onPressed: _open,
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: 'Download changes (Ctrl/Cmd+S)',
              onPressed: _name == null ? null : _save,
              icon: const Icon(Icons.save_alt_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: _name == null
                  ? Center(
                      child: FilledButton.icon(
                        onPressed: _open,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open a text file'),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        focusNode: _focus,
                        controller: _code,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.5,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
            ),
            if (_name != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('$_name • Save downloads a new copy'),
              ),
          ],
        ),
      ),
    ),
  );
}

class SaveIntent extends Intent {
  const SaveIntent();
}

class OpenIntent extends Intent {
  const OpenIntent();
}
