import { init, Terminal } from './ghostty-web.js';

const mount = document.getElementById('terminal');
const status = document.getElementById('status');
const project = new URLSearchParams(location.search).get('project');

if (!project) {
  status.textContent = 'No project selected';
  throw new Error('A project is required for the terminal');
}

await init();
const terminal = new Terminal({
  cursorBlink: true,
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
  fontSize: 13,
  theme: { background: '#0d1117', foreground: '#c9d1d9', cursor: '#7c9cff' },
});
terminal.open(mount);

const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
const socket = new WebSocket(
  `${scheme}//${location.host}/api/projects/${encodeURIComponent(project)}/terminal`,
);
socket.binaryType = 'arraybuffer';
const decoder = new TextDecoder();

function resize() {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ type: 'resize', cols: terminal.cols, rows: terminal.rows }));
  }
}

socket.addEventListener('open', () => {
  status.textContent = 'Connected';
  resize();
  terminal.focus();
});
socket.addEventListener('message', (event) => {
  if (typeof event.data === 'string') {
    terminal.write(event.data);
  } else {
    terminal.write(decoder.decode(event.data, { stream: true }));
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
new ResizeObserver(resize).observe(mount);
addEventListener('beforeunload', () => socket.close());
