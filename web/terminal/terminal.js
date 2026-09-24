import { FitAddon, init, Terminal } from './ghostty-web.js';

const mount = document.getElementById('terminal');
const status = document.getElementById('status');
const project = new URLSearchParams(location.search).get('project');
const session = new URLSearchParams(location.search).get('session');

if (!project || !session) {
  status.textContent = 'No terminal session selected';
  throw new Error('A project and terminal session are required');
}

await init();
const terminal = new Terminal({
  cursorBlink: true,
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
  fontSize: 13,
  theme: { background: '#0d1117', foreground: '#c9d1d9', cursor: '#7c9cff' },
});
terminal.open(mount);
const fitAddon = new FitAddon();
terminal.loadAddon(fitAddon);

const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
const socket = new WebSocket(
  `${scheme}//${location.host}/api/projects/${encodeURIComponent(project)}/terminal?session=${encodeURIComponent(session)}`,
);
socket.binaryType = 'arraybuffer';
const decoder = new TextDecoder();

function sendResize({ cols = terminal.cols, rows = terminal.rows } = {}) {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'resize', cols, rows }));
  }
}

socket.addEventListener('open', () => {
  status.textContent = 'Connected';
  sendResize();
  terminal.focus();
});
socket.addEventListener('message', (event) => {
  // `Terminal.write` follows new output to the bottom. Keep the reader's
  // place in scrollback instead when they have intentionally scrolled up.
  const viewportY = terminal.getViewportY();
  const scrollbackLength = terminal.getScrollbackLength();

  if (typeof event.data === 'string') {
    terminal.write(event.data);
  } else {
    terminal.write(decoder.decode(event.data, { stream: true }));
  }

  if (viewportY > 0) {
    terminal.scrollToLine(viewportY + terminal.getScrollbackLength() - scrollbackLength);
  }
});
socket.addEventListener('close', (event) => {
  status.textContent = event.code === 1000 ? 'Disconnected' : 'Terminal disconnected';
});
socket.addEventListener('error', () => { status.textContent = 'Terminal error'; });
terminal.onData((data) => {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'input', data }));
  }
});
terminal.onResize(sendResize);
fitAddon.fit();
fitAddon.observeResize();
addEventListener('beforeunload', () => socket.close());
