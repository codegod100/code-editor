const mount = document.getElementById('terminal');
const status = document.getElementById('status');
const project = new URLSearchParams(location.search).get('project');
const session = new URLSearchParams(location.search).get('session');

if (!project || !session) {
  status.textContent = 'No terminal session selected';
  throw new Error('A project and terminal session are required');
}

// Start the shell while the browser downloads and initializes the comparatively
// large terminal renderer and its WebAssembly module. Shell startup used to sit
// entirely behind that work, making every new terminal pay both costs serially.
const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
const socket = new WebSocket(
  `${scheme}//${location.host}/api/projects/${encodeURIComponent(project)}/terminal?session=${encodeURIComponent(session)}`,
);
socket.binaryType = 'arraybuffer';

let terminal;
let fitAddon;
let connected = false;
const pendingOutput = [];
const decoder = new TextDecoder();

socket.addEventListener('open', () => {
  connected = true;
  status.textContent = terminal ? 'Connected' : 'Starting terminal…';
  if (terminal) {
    sendResize();
    terminal.focus();
  }
});
socket.addEventListener('message', (event) => {
  if (!terminal) {
    pendingOutput.push(event.data);
    return;
  }
  writeOutput(event.data);
});
socket.addEventListener('close', (event) => {
  connected = false;
  status.textContent = event.code === 1000 ? 'Disconnected' : 'Terminal disconnected';
});
socket.addEventListener('error', () => { status.textContent = 'Terminal error'; });

const { FitAddon, init, Terminal } = await import('./ghostty-web.js');
await init();
terminal = new Terminal({
  cursorBlink: true,
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
  fontSize: 13,
  theme: { background: '#0d1117', foreground: '#c9d1d9', cursor: '#7c9cff' },
});
terminal.open(mount);
fitAddon = new FitAddon();
terminal.loadAddon(fitAddon);

function sendResize({ cols = terminal.cols, rows = terminal.rows } = {}) {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'resize', cols, rows }));
  }
}

function writeOutput(data) {
  // `Terminal.write` follows new output to the bottom. Keep the reader's
  // place in scrollback instead when they have intentionally scrolled up.
  const viewportY = terminal.getViewportY();
  const scrollbackLength = terminal.getScrollbackLength();

  if (typeof data === 'string') {
    terminal.write(data);
  } else {
    terminal.write(decoder.decode(data, { stream: true }));
  }

  if (viewportY > 0) {
    terminal.scrollToLine(viewportY + terminal.getScrollbackLength() - scrollbackLength);
  }
}

for (const output of pendingOutput) writeOutput(output);
pendingOutput.length = 0;
terminal.onData((data) => {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'input', data }));
  }
});
terminal.onResize(sendResize);
fitAddon.fit();
fitAddon.observeResize();
if (connected) {
  status.textContent = 'Connected';
  sendResize();
  terminal.focus();
}
addEventListener('beforeunload', () => socket.close());
