'use strict';

// The Office session is the only identity source. No cookies, tokens, remote
// titles, URLs, frames, or input are copied to storage, logs, or global objects.
const byId = id => document.getElementById(id);
const app = byId('browser-app');
const screen = byId('rfb-screen');
const keyboard = byId('keyboard-input');
const isLocal = ['localhost', '127.0.0.1'].includes(location.hostname);
const validModes = new Set(['paused', 'agent', 'handoff', 'human']);
const errorMessages = {
  browser_not_running: '工作瀏覽器尚未啟動，請稍後重新連線。',
  browser_disabled: '這個辦公室尚未開啟工作瀏覽器。',
  browser_unavailable: '暫時連不到工作瀏覽器服務，請稍後重新連線。',
  stale_epoch: '控制權已變更，請確認目前狀態後再操作。',
  browser_busy: '瀏覽器正在交接控制權，請稍後再試。',
  owner_mismatch: '這次接管屬於另一台裝置，請由該裝置交還控制權。',
  private_session: '瀏覽器正在私人接管中，這台裝置暫時不能觀看。',
  control_already_connected: '這台裝置已有接管視窗，請先使用原來的視窗。',
  control_not_connected: '接管連線尚未建立，請再次按「接管」。',
  invalid_request: '操作沒有完成，請重新讀取狀態後再試。',
  handoff_failed: '控制權交接未完成，瀏覽器會保持暫停。',
  invalid_state: '暫時無法確認瀏覽器狀態，請重新連線。',
  session_unavailable: '暫時無法確認辦公室配對，請重新連線。',
  network_unavailable: '連線中斷，請檢查網路後重新連線。',
  request_failed: '操作沒有完成，請重新確認瀏覽器狀態。',
};
let token = '';
let authenticated = false;
let state = null;
let busy = false;
let stateRequest = null;
let revision = 0;
let streamAttempt = 0;
let stream = null;
let connection = 'idle';
let rfbModule = null;
let composing = false;
let inputSuspended = false;
// Like noVNC's mobile UI, a focusable textarea receives native keyboard input
// and RFB.sendKey() forwards it. The padding lets mobile backspace fire even
// though committed text is cleared immediately. No clipboard API is used.
// Reference: https://github.com/novnc/noVNC/blob/v1.7.0/app/ui.js
const keyboardPadding = '_'.repeat(32);
const specialKeys = {
  Backspace: [0xff08, 'Backspace'], Tab: [0xff09, 'Tab'],
  Enter: [0xff0d, 'Enter'], Escape: [0xff1b, 'Escape'],
  Delete: [0xffff, 'Delete'], ArrowLeft: [0xff51, 'ArrowLeft'],
  ArrowUp: [0xff52, 'ArrowUp'], ArrowRight: [0xff53, 'ArrowRight'],
  ArrowDown: [0xff54, 'ArrowDown'], Home: [0xff50, 'Home'], End: [0xff57, 'End'],
};

class RequestError extends Error {
  constructor(code, status = 0) {
    super(errorMessages[code] || errorMessages.request_failed);
    this.code = code;
    this.status = status;
  }
}

function notice(text = '', tone = '') {
  byId('notice').textContent = text;
  byId('notice').dataset.tone = tone;
}

function placeholder(title, detail) {
  byId('placeholder-title').textContent = title;
  byId('placeholder-detail').textContent = detail;
  byId('viewer-placeholder').hidden = false;
}

function canType() {
  return authenticated && !busy && !inputSuspended && stream?.mode === 'control'
    && connection === 'connected' && state?.mode === 'human'
    && state.is_owner && stream.epoch === state.epoch && !document.hidden;
}

function resetKeyboard() {
  keyboard.value = keyboardPadding;
  keyboard.setSelectionRange(keyboardPadding.length, keyboardPadding.length);
}

function hideKeyboard() {
  composing = false;
  keyboard.blur();
  keyboard.value = '';
  byId('keyboard-toggle').setAttribute('aria-pressed', 'false');
  byId('keyboard-toggle').setAttribute('aria-label', '開啟手機鍵盤');
  byId('keyboard-tools').hidden = true;
  if (stream) stream.rfb.focusOnClick = true;
}

function disconnectStream() {
  streamAttempt += 1;
  const previous = stream;
  stream = null;
  hideKeyboard();
  if (previous) {
    previous.rfb.viewOnly = true;
    previous.rfb.disconnect();
  }
  screen.replaceChildren();
  connection = 'disconnected';
}

function render() {
  app.dataset.mode = state?.mode || 'unknown';
  app.dataset.connection = connection;
  app.dataset.streamMode = stream?.mode || 'none';
  app.dataset.private = String(Boolean(state?.private));
  app.dataset.isOwner = String(Boolean(state?.is_owner));
  app.setAttribute('aria-busy', String(busy));
  const liveControl = stream?.mode === 'control' && connection === 'connected';
  byId('takeover').disabled = !authenticated || busy || !state?.can_takeover;
  byId('release').disabled = !authenticated || busy || !state?.can_release;
  byId('reconnect').disabled = busy || liveControl;
  byId('keyboard-toggle').disabled = !canType();
  keyboard.disabled = !canType();
  document.querySelectorAll('[data-key]').forEach(button => { button.disabled = !canType(); });
  if (!canType() && document.activeElement === keyboard) hideKeyboard();
  byId('privacy-badge').hidden = !state?.private;
  byId('connection-status').textContent = ({
    idle: '正在確認連線', connecting: '畫面連線中', connected: '已連上 VPS',
    disconnected: '畫面未連線', error: '連線需要處理',
  })[connection];
  byId('interaction-label').textContent = connection === 'connected'
    ? (canType() ? '你正在操作' : '只看畫面') : '尚未連線';
  if (!authenticated) return;
  if (!state) {
    byId('state-title').textContent = '等待工作瀏覽器';
    byId('state-summary').textContent = '配對有效，正在確認遠端瀏覽器的狀態。';
    return;
  }
  const copy = {
    agent: ['控制權已交還 Agent', '目前可觀看畫面；需要手動操作時，按「接管」。'],
    handoff: ['正在交接控制權', '等待前一個操作結束後，才會開放新的操作。'],
    paused: state.private
      ? ['接管已暫停', state.is_owner
        ? '私人畫面仍受保護。先按「接管」接續，完成後再交還 Agent。'
        : '請等原來接管的裝置交還控制權，再觀看畫面。']
      : ['瀏覽器暫停中', '現在可以觀看；按「接管」後才能點擊、輸入或登入。'],
    human: state.is_owner
      ? ['你已取得接管權', canType()
        ? '你正在操作同一個 Chrome；其他觀看連線已暫停。'
        : '控制權保留在這台裝置，正在確認接管畫面的連線。']
      : ['另一台裝置正在接管', '私人接管期間，這裡暫停顯示畫面。'],
  }[state.mode];
  byId('state-title').textContent = copy[0];
  byId('state-summary').textContent = copy[1];
  byId('screen-hint').textContent = canType()
    ? '可以直接點擊畫面。手機請先點遠端輸入欄位，再按「鍵盤」；輸入完成後按「交還 Agent」。'
    : '觀看模式不會傳送滑鼠或鍵盤操作。需要輸入或登入時，先按「接管」。';
}

function requirePairing() {
  authenticated = false;
  token = '';
  state = null;
  disconnectStream();
  byId('state-title').textContent = '請先配對這台裝置';
  byId('state-summary').textContent = '工作瀏覽器沿用辦公室的裝置配對。';
  byId('pairing-link').hidden = false;
  placeholder('需要辦公室配對', '返回辦公室完成配對後，再開啟工作瀏覽器。');
  notice('這台裝置尚未配對，或原本的配對已失效。', 'error');
  render();
}

async function request(path, body, retry = true) {
  const controller = new AbortController();
  // Handoff may drain an in-flight browser action. Let Office's 45-second
  // mutation deadline finish before giving up on the response here.
  const timeout = setTimeout(() => controller.abort(), body === undefined ? 20_000 : 50_000);
  let response;
  let data = {};
  try {
    response = await fetch(path, {
      cache: 'no-store', credentials: 'same-origin', signal: controller.signal,
      ...(body === undefined ? {} : {
        method: 'POST', headers: {'Content-Type': 'application/json', 'X-Office-Token': token},
        body: JSON.stringify(body),
      }),
    });
    try {
      const parsed = await response.json();
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) data = parsed;
    } catch { /* Never display raw responses. */ }
  } catch {
    throw new RequestError('network_unavailable');
  } finally {
    clearTimeout(timeout);
  }
  if (response.status === 401) {
    requirePairing();
    throw new RequestError('session_unavailable', 401);
  }
  if (response.status === 403 && data.token_expired === true && body !== undefined && retry) {
    // Office rejects an expired page token before dispatching a mutation.
    // This is the only automatic mutation retry; network/stale-epoch errors
    // are reconciled through GET state and never replay a control request.
    await establishSession();
    return request(path, body, false);
  }
  if (!response.ok) {
    const code = Object.hasOwn(errorMessages, data.error) ? data.error : 'request_failed';
    throw new RequestError(code, response.status);
  }
  return data;
}

async function establishSession() {
  if (!isLocal && location.protocol !== 'https:') throw new RequestError('session_unavailable');
  const session = await request(isLocal ? '/api/bootstrap' : '/api/session');
  if (typeof session.token !== 'string' || !session.token || session.token.length > 256) {
    throw new RequestError('session_unavailable');
  }
  token = session.token;
  authenticated = true;
  byId('pairing-link').hidden = true;
}

function parseState(value) {
  if (!value || typeof value !== 'object' || !validModes.has(value.mode)
      || !Number.isSafeInteger(value.epoch) || value.epoch < 0
      || typeof value.session_id !== 'string'
      || ['private', 'is_owner', 'control_connected', 'can_view', 'can_takeover', 'can_release']
        .some(key => typeof value[key] !== 'boolean')) {
    throw new RequestError('invalid_state');
  }
  return value;
}

function applyState(value) {
  const next = parseState(value);
  state = next;
  if (stream && (stream.epoch !== next.epoch
      || (stream.mode === 'view' && !next.can_view)
      || (stream.mode === 'control' && (next.mode !== 'human' || !next.is_owner)))) {
    disconnectStream();
  }
  if (!stream && !next.can_view) {
    placeholder(next.private ? '私人接管中' : '正在交接控制權', next.is_owner
      ? '畫面只在這台裝置明確接管後開啟。' : '請等接管者交還控制權。');
  }
  render();
  return next;
}

async function refreshState() {
  if (stateRequest) return stateRequest;
  const expectedRevision = revision;
  const running = (async () => {
    try {
      const next = await request('/api/browser/state');
      if (expectedRevision !== revision) return null;
      return applyState(next);
    } catch (error) {
      if (expectedRevision !== revision) return null;
      throw error;
    }
  })();
  stateRequest = running;
  try { return await running; }
  finally { if (stateRequest === running) stateRequest = null; }
}

function displayFailure(error) {
  if (error.status === 401) return;
  disconnectStream();
  state = null;
  connection = 'error';
  notice(error instanceof RequestError ? error.message : errorMessages.request_failed, 'error');
  placeholder('畫面暫時無法開啟', '確認連線後按「重新連線」。接管不會自動交還。');
  render();
}

async function connectStream(mode, epoch) {
  if (document.hidden || !authenticated || !state || state.epoch !== epoch) return;
  if (mode === 'view' ? !state.can_view : (state.mode !== 'human' || !state.is_owner)) return;
  disconnectStream();
  const attempt = streamAttempt;
  connection = 'connecting';
  placeholder('畫面連線中', mode === 'control' ? '正在連到你已接管的 Chrome。' : '正在載入遠端 Chrome 的畫面。');
  render();
  try {
    if (!rfbModule) rfbModule = await import('/browser/novnc.js');
    if (attempt !== streamAttempt || !authenticated || document.hidden || state?.epoch !== epoch) return;
    const url = new URL('/api/browser/ws', location.href);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('mode', mode);
    url.searchParams.set('epoch', String(epoch));
    const rfb = new rfbModule.default(screen, url.href, {shared: true});
    const record = {rfb, mode, epoch};
    stream = record;
    rfb.viewOnly = mode !== 'control' || inputSuspended;
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.showDotCursor = mode === 'control';
    rfb.background = '#e9ece3';
    rfb.qualityLevel = 7;
    rfb.addEventListener('connect', () => {
      if (stream !== record) return;
      connection = 'connected';
      byId('viewer-placeholder').hidden = true;
      notice(mode === 'control' ? '已接管。完成登入或操作後，請明確交還控制權。' : '已連上畫面，目前僅供觀看。');
      render();
      if (!busy) refreshState().catch(displayFailure);
    });
    rfb.addEventListener('disconnect', () => {
      if (stream !== record) return;
      disconnectStream();
      placeholder('畫面連線已中斷', mode === 'control'
        ? '接管會保持暫停；請再次按「接管」，不會自動恢復操作。'
        : '按「重新連線」重新觀看同一個 Chrome。');
      notice(mode === 'control'
        ? '接管連線中斷，正在確認暫停狀態。請勿重複原本的操作。'
        : '觀看連線已中斷，遠端 Chrome 仍會保留。');
      render();
      if (!busy) refreshState().catch(displayFailure);
    });
    for (const event of ['credentialsrequired', 'securityfailure', 'serververification']) {
      rfb.addEventListener(event, () => {
        if (stream !== record) return;
        disconnectStream();
        connection = 'error';
        placeholder('畫面服務需要處理', '請回辦公室確認服務設定，再重新連線。');
        notice('畫面服務未能完成連線，這裡不會另外索取帳號或密碼。', 'error');
        render();
      });
    }
    // There is intentionally no clipboard handler or clipboardPasteFrom call.
  } catch {
    if (attempt !== streamAttempt) return;
    disconnectStream();
    connection = 'error';
    placeholder('畫面元件暫時無法載入', '請稍後按「重新連線」。');
    notice('畫面連線沒有完成，瀏覽器控制權不會自動交還。', 'error');
    render();
  }
}

async function runAction(action) {
  if (busy || !state || !authenticated) return;
  if (action === 'takeover' ? !state.can_takeover : !state.can_release) return;
  busy = true;
  revision += 1;
  stateRequest = null;
  const epoch = state.epoch;
  inputSuspended = true;
  hideKeyboard();
  if (stream) stream.rfb.viewOnly = true;
  // Release while the control socket is still alive. Closing it first changes
  // the server epoch to a private pause and would make this release stale.
  if (action === 'takeover') disconnectStream();
  notice(action === 'takeover' ? '正在接管工作瀏覽器…' : '正在交還瀏覽器控制權…');
  render();
  try {
    const next = applyState(await request('/api/browser/' + action, action === 'release' ? {epoch} : {}));
    inputSuspended = false;
    busy = false;
    if (action === 'takeover' && next.mode === 'human' && next.is_owner) {
      await connectStream('control', next.epoch);
    } else if (next.can_view) {
      await connectStream('view', next.epoch);
    }
  } catch (error) {
    // An interrupted response can still have reached the server. Stop input,
    // reconcile state, and require an explicit new takeover; never replay it.
    disconnectStream();
    if (error.status !== 401) {
      notice(error instanceof RequestError ? error.message : errorMessages.request_failed, 'error');
      try { await refreshState(); } catch (refreshError) { displayFailure(refreshError); }
    }
  } finally {
    busy = false;
    render();
  }
}

async function reconnect() {
  if (busy || (stream?.mode === 'control' && connection === 'connected')) return;
  busy = true;
  revision += 1;
  stateRequest = null;
  disconnectStream();
  notice('正在重新確認辦公室配對與瀏覽器狀態…');
  render();
  try {
    await establishSession();
    const next = await refreshState();
    if (next?.can_view) await connectStream('view', next.epoch);
    else if (next?.is_owner) notice(next.mode === 'paused'
      ? '瀏覽器仍為私人暫停。先按「接管」接續，完成後再交還 Agent。'
      : '控制權仍保留在這台裝置。請確認原來的接管視窗，或明確交還 Agent。');
  } catch (error) { displayFailure(error); }
  finally { busy = false; render(); }
}

function sendSpecial(name) {
  if (!canType() || !specialKeys[name]) return;
  stream.rfb.sendKey(...specialKeys[name]);
}

function sendCharacters(text) {
  if (!canType()) return;
  // RFB uses Latin-1 directly and the X11 Unicode keysym range for other code
  // points. Iterate code points, never UTF-16 halves, for composed input.
  for (const character of text) {
    const point = character.codePointAt(0);
    if (point === 10 || point === 13) sendSpecial('Enter');
    else if (point === 9) sendSpecial('Tab');
    else if (point >= 32 && point !== 127) stream.rfb.sendKey(point < 256 ? point : (0x01000000 | point));
  }
}

function flushKeyboard(event) {
  if (composing || event?.isComposing) return;
  if (!canType()) { keyboard.value = ''; return; }
  const inputType = event?.inputType || '';
  if (/Paste|Drop/.test(inputType)) { resetKeyboard(); return; }
  const value = keyboard.value;
  if (inputType.startsWith('delete')) {
    sendSpecial(inputType.includes('Forward') ? 'Delete' : 'Backspace');
  } else if (inputType === 'insertLineBreak' || inputType === 'insertParagraph') {
    sendSpecial('Enter');
  } else {
    let start = 0;
    while (start < keyboardPadding.length && value[start] === keyboardPadding[start]) start += 1;
    sendCharacters(value.slice(start));
  }
  resetKeyboard();
}

byId('takeover').addEventListener('click', () => runAction('takeover'));
byId('release').addEventListener('click', () => runAction('release'));
byId('reconnect').addEventListener('click', reconnect);
byId('keyboard-toggle').addEventListener('pointerdown', event => {
  if (document.activeElement === keyboard) event.preventDefault();
});
byId('keyboard-toggle').addEventListener('click', () => {
  if (!canType()) return;
  if (document.activeElement === keyboard) { hideKeyboard(); return; }
  resetKeyboard();
  // Focus must happen synchronously in this tap for iOS to open its keyboard.
  keyboard.focus({preventScroll: true});
});
keyboard.addEventListener('focus', () => {
  if (!canType()) { hideKeyboard(); return; }
  byId('keyboard-toggle').setAttribute('aria-pressed', 'true');
  byId('keyboard-toggle').setAttribute('aria-label', '收起手機鍵盤');
  byId('keyboard-tools').hidden = false;
  stream.rfb.focusOnClick = false;
});
keyboard.addEventListener('blur', () => {
  composing = false;
  keyboard.value = '';
  byId('keyboard-toggle').setAttribute('aria-pressed', 'false');
  byId('keyboard-toggle').setAttribute('aria-label', '開啟手機鍵盤');
  byId('keyboard-tools').hidden = true;
  if (stream) stream.rfb.focusOnClick = true;
});
keyboard.addEventListener('keydown', event => {
  if (!canType() || event.isComposing || composing) return;
  if (specialKeys[event.key] && !event.ctrlKey && !event.metaKey && !event.altKey) {
    event.preventDefault();
    sendSpecial(event.key);
    resetKeyboard();
  }
});
keyboard.addEventListener('beforeinput', event => {
  if (/Paste|Drop/.test(event.inputType)) event.preventDefault();
});
keyboard.addEventListener('compositionstart', () => { composing = true; });
keyboard.addEventListener('compositionend', () => {
  composing = false;
  // Some keyboards fire their committed input after compositionend. Reading
  // once after this task also avoids sending both the composition and input.
  queueMicrotask(() => flushKeyboard());
});
keyboard.addEventListener('input', flushKeyboard);
for (const type of ['paste', 'copy', 'cut', 'drop']) {
  document.addEventListener(type, event => {
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
}
screen.addEventListener('mousedown', event => {
  if (document.activeElement === keyboard) event.preventDefault();
}, true);
for (const button of document.querySelectorAll('[data-key]')) {
  button.addEventListener('pointerdown', event => {
    if (document.activeElement === keyboard) event.preventDefault();
  });
  button.addEventListener('click', () => sendSpecial(button.dataset.key));
}
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    revision += 1;
    stateRequest = null;
    disconnectStream();
    placeholder('觀看已暫停', '回到頁面後重新連線。接管中的瀏覽器不會自動交還。');
    render();
  } else if (authenticated && !busy) {
    refreshState().catch(displayFailure);
  }
});
window.addEventListener('pagehide', () => {
  revision += 1;
  disconnectStream();
  token = '';
  authenticated = false;
});
window.addEventListener('pageshow', event => { if (event.persisted) reconnect(); });
setInterval(() => {
  if (authenticated && !busy && !document.hidden) refreshState().catch(displayFailure);
}, 2500);

render();
reconnect();
