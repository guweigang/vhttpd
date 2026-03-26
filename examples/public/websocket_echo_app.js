(function () {
  const root = document.querySelector('[data-websocket-demo="1"]');
  if (!root) return;

  const urlInput = document.getElementById('ws-url');
  const messageInput = document.getElementById('ws-message');
  const logOutput = document.getElementById('ws-log');
  const status = document.getElementById('ws-status');
  const connectBtn = document.getElementById('ws-connect');
  const sendBtn = document.getElementById('ws-send');
  const byeBtn = document.getElementById('ws-bye');
  const disconnectBtn = document.getElementById('ws-disconnect');
  const clearBtn = document.getElementById('ws-clear');

  let socket = null;

  function append(line) {
    const ts = new Date().toLocaleTimeString();
    logOutput.value += `[${ts}] ${line}\n`;
    logOutput.scrollTop = logOutput.scrollHeight;
  }

  function setStatus(text) {
    status.textContent = text;
  }

  function setConnected(connected) {
    connectBtn.disabled = connected;
    sendBtn.disabled = !connected;
    byeBtn.disabled = !connected;
    disconnectBtn.disabled = !connected;
  }

  function connect() {
    if (socket && socket.readyState === WebSocket.OPEN) return;

    const url = urlInput.value.trim();
    if (!url) {
      setStatus('WebSocket URL is required.');
      return;
    }

    setStatus('Connecting...');
    append(`CONNECT ${url}`);
    socket = new WebSocket(url);

    socket.addEventListener('open', () => {
      setConnected(true);
      setStatus('Connected.');
      append('OPEN');
    });

    socket.addEventListener('message', (event) => {
      append(`RECV ${event.data}`);
    });

    socket.addEventListener('close', (event) => {
      setConnected(false);
      setStatus(`Closed (${event.code}${event.reason ? `, ${event.reason}` : ''}).`);
      append(`CLOSE code=${event.code} reason=${event.reason || ''}`);
      socket = null;
    });

    socket.addEventListener('error', () => {
      setStatus('Socket error.');
      append('ERROR');
    });
  }

  function sendMessage(value) {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setStatus('Connect first.');
      return;
    }
    append(`SEND ${value}`);
    socket.send(value);
  }

  connectBtn.addEventListener('click', connect);
  sendBtn.addEventListener('click', () => sendMessage(messageInput.value));
  byeBtn.addEventListener('click', () => sendMessage('bye'));
  disconnectBtn.addEventListener('click', () => {
    if (socket) socket.close(1000, 'client disconnect');
  });
  clearBtn.addEventListener('click', () => {
    logOutput.value = '';
    setStatus('Idle.');
  });

  setConnected(false);
})();
