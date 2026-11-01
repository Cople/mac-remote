'use strict';

const $ = (id) => document.getElementById(id);
let state = null;
let online = false;
let paired = false;
let mode = 'keyboard';
let commandQueue = Promise.resolve();
let toastTimer;
let polling = false;
let draggingVolume = false;
let pendingVolume = null;
let volumeSending = false;
let notificationBusy = false;
let hold = null;
let keyboardHolding = false;
const fragment = new URLSearchParams(location.hash.slice(1));
let initialToken = fragment.get('token');
// Keep the pairing secret out of navigation history, HTTP requests and referrers.
if (location.hash) history.replaceState(null, '', location.pathname);

async function api(path, payload, {keepalive = false} = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), path === '/api/command' && payload?.action === 'clearNotifications' ? 9500 : 4500);
  try {
    const response = await fetch(path, {
      method: payload === undefined ? 'GET' : 'POST',
      headers: payload === undefined ? {} : {'Content-Type': 'application/json'},
      credentials: 'same-origin', cache: 'no-store',
      body: payload === undefined ? undefined : JSON.stringify(payload),
      signal: controller.signal, keepalive
    });
    const result = await response.json();
    if (!response.ok) {
      const error = new Error(result.error || '操作失败，请重试');
      error.status = response.status;
      throw error;
    }
    return result;
  } finally { clearTimeout(timeout); }
}

function toast(message, error = false) {
  clearTimeout(toastTimer);
  $('toast').textContent = message;
  $('toast').classList.toggle('error', error);
  $('toast').hidden = false;
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, error ? 6500 : 2300);
}

function setConnection(connected) {
  online = connected;
  $('connection-label').textContent = connected ? '已连接' : '未连接';
  $('connection-status').classList.toggle('offline', !connected);
  $('connection-status').classList.remove('connecting');
  updateControls();
}

function updateControls() {
  const ready = paired && online && !notificationBusy;
  document.querySelectorAll('[data-control]').forEach((button) => {
    const type = button.dataset.control;
    button.disabled = !ready || (type === 'keyboard' && !state?.accessibility)
      || (type === 'volume' && !state?.volumeControllable)
      || (type === 'mute' && typeof state?.muted !== 'boolean');
  });
  $('volume-slider').disabled = !ready || !state?.volumeControllable;
  $('permission-banner').hidden = !paired || !online || !!state?.accessibility;
}

function applyState(next) {
  state = next;
  paired = true;
  $('pairing-overlay').hidden = true;
  $('device-name').textContent = next.name || 'Mac';
  $('frontmost-app').textContent = next.frontmostApp ? `当前应用 · ${next.frontmostApp}` : '—';
  for (const [key, fallback] of Object.entries({previous: '[', next: ']', fullscreen: 'F'})) {
    document.querySelector(`[data-key="${key}"] kbd`).textContent = next.shortcutLabels?.[key] || fallback;
  }
  const icon = $('frontmost-app-icon');
  const hasIcon = typeof next.frontmostAppIcon === 'string' && next.frontmostAppIcon.startsWith('data:image/png;base64,');
  if (hasIcon) {
    if (icon.getAttribute('src') !== next.frontmostAppIcon) icon.src = next.frontmostAppIcon;
  } else icon.removeAttribute('src');
  icon.hidden = !hasIcon;
  $('app-icon-fallback').toggleAttribute('hidden', hasIcon);
  if (!draggingVolume && !volumeSending) setVolumeDisplay(next.volume);
  $('mute-button').classList.toggle('is-muted', !!next.muted);
  $('mute-label').textContent = next.muted ? '取消静音' : '静音';
  $('mute-icon').setAttribute('href', next.muted ? '#i-volume' : '#i-mute');
  $('volume-note').hidden = !!next.volumeControllable;
  setConnection(true);
}

function setVolumeDisplay(value) {
  const percent = typeof value === 'number' ? Math.round(value * 100) : null;
  $('volume-value').replaceChildren(document.createTextNode(percent === null ? '—' : String(percent)));
  const suffix = document.createElement('span');
  suffix.textContent = '%';
  $('volume-value').append(suffix);
  $('volume-slider').value = percent ?? 0;
  $('volume-slider').style.setProperty('--volume', `${percent ?? 0}%`);
}

function handleError(error, quiet = false) {
  if (error.status === 401) {
    paired = false;
    endHold();
    showPairing(error.message);
    setConnection(false);
  } else if (!error.status) {
    setConnection(false);
    if (!quiet) toast('连接中断，请检查 Mac 和局域网连接', true);
  } else if (!quiet) {
    toast(error.message, true);
  }
}

function command(payload, {quiet = false, keepalive = false, allowOffline = false} = {}) {
  const operation = async () => {
    if ((!paired || !online) && !allowOffline) return null;
    try {
      const next = await api('/api/command', payload, {keepalive});
      applyState(next);
      return next;
    } catch (error) { handleError(error, quiet); return null; }
  };
  const pending = commandQueue.then(operation, operation);
  commandQueue = pending.catch(() => {});
  return pending;
}

async function refresh() {
  if (polling || notificationBusy || document.hidden) return;
  polling = true;
  try { applyState(await api('/api/state')); }
  catch (error) { handleError(error, true); }
  finally { polling = false; }
}

function showPairing(message) {
  $('pairing-overlay').hidden = false;
  if (message) $('pairing-message').textContent = message;
  updateControls();
}

async function pair(token) {
  const submit = $('pairing-submit');
  submit.disabled = true;
  try {
    applyState(await api('/api/pair', {token}));
    $('pairing-token').value = '';
    toast('已连接');
  } catch (error) {
    paired = false;
    setConnection(false);
    showPairing(error.status ? error.message : '无法连接，请检查局域网和 Mac 的本地网络权限。');
  } finally { submit.disabled = false; }
}

$('pairing-form').addEventListener('submit', (event) => {
  event.preventDefault();
  let token = $('pairing-token').value.trim();
  try {
    const url = new URL(token);
    token = new URLSearchParams(url.hash.slice(1)).get('token') || '';
  } catch { /* A raw token is accepted as well. */ }
  if (!/^[0-9]{6}$/.test(token)) {
    toast('请输入 6 位数字配对码或粘贴连接地址', true);
    return;
  }
  pair(token);
});

function changeMode(next) {
  endHold();
  mode = next;
  for (const name of ['keyboard', 'media']) {
    const selected = name === mode;
    $(`mode-${name}`).classList.toggle('active', selected);
    $(`mode-${name}`).setAttribute('aria-selected', String(selected));
    $(`mode-${name}`).tabIndex = selected ? 0 : -1;
  }
  $('remote-controls').setAttribute('aria-labelledby', `mode-${mode}`);
  $('left-icon').setAttribute('href', mode === 'keyboard' ? '#i-back' : '#i-prev');
  $('right-icon').setAttribute('href', mode === 'keyboard' ? '#i-forward' : '#i-next');
  $('left-label').textContent = mode === 'keyboard' ? '5 秒' : '上一首';
  $('right-label').textContent = mode === 'keyboard' ? '5 秒' : '下一首';
  $('pad-left').setAttribute('aria-label', mode === 'keyboard' ? '快退，发送左箭头' : '上一首媒体按键');
  $('pad-right').setAttribute('aria-label', mode === 'keyboard' ? '快进，长按持续发送右箭头' : '下一首媒体按键');
  $('hold-hint').hidden = mode !== 'keyboard';
  $('shortcut-grid').hidden = mode !== 'keyboard';
}

$('mode-keyboard').addEventListener('click', () => changeMode('keyboard'));
$('mode-media').addEventListener('click', () => changeMode('media'));
document.querySelectorAll('[role=tab]').forEach((tab) => tab.addEventListener('keydown', (event) => {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
  event.preventDefault();
  changeMode(event.key === 'Home' ? 'keyboard' : event.key === 'End' ? 'media' : mode === 'keyboard' ? 'media' : 'keyboard');
  $(`mode-${mode}`).focus();
}));

$('pad-play').addEventListener('click', () => command(mode === 'keyboard' ? {action: 'key', key: 'space'} : {action: 'media', media: 'playPause'}));
$('pad-left').addEventListener('click', () => command(mode === 'keyboard' ? {action: 'key', key: 'left'} : {action: 'media', media: 'previous'}));
$('pad-up').addEventListener('click', () => command({action: 'volumeStep', value: 0.1}));
$('pad-down').addEventListener('click', () => command({action: 'volumeStep', value: -0.1}));
$('volume-up').addEventListener('click', () => command({action: 'volumeStep', value: 0.1}));
$('volume-down').addEventListener('click', () => command({action: 'volumeStep', value: -0.1}));
$('mute-button').addEventListener('click', () => command({action: 'mute'}));
document.querySelectorAll('[data-key]').forEach((button) => button.addEventListener('click', () => command({action: 'key', key: button.dataset.key})));

const rightButton = $('pad-right');
function setHoldUI(active) {
  rightButton.classList.toggle('holding', active);
  $('hold-hint').classList.toggle('is-holding', active);
  $('hold-text').textContent = active ? '松开恢复' : '长按倍速';
}

function startHold(pointerId = null) {
  if (rightButton.disabled || hold) return;
  if (mode === 'media') return;
  const current = {pointerId, timer: null, heartbeat: null, started: false};
  hold = current;
  current.timer = setTimeout(async () => {
    if (hold !== current) return;
    current.started = true;
    setHoldUI(true);
    const result = await command({action: 'holdStart'});
    if (!result) { endHold(); return; }
    if (hold !== current) return; // The queued holdEnd follows the pending holdStart.
    current.heartbeat = setInterval(async () => {
      const renewed = await command({action: 'holdHeartbeat'}, {quiet: true});
      if (!renewed && hold === current) endHold();
    }, 400);
  }, 320);
}

function endHold(tap = false) {
  const current = hold;
  if (!current) return;
  hold = null;
  clearTimeout(current.timer);
  clearInterval(current.heartbeat);
  setHoldUI(false);
  if (current.started) command({action: 'holdEnd'}, {quiet: true, keepalive: true, allowOffline: true});
  else if (tap) command({action: 'key', key: 'right'});
}

rightButton.addEventListener('pointerdown', (event) => {
  if (event.button !== 0 || rightButton.disabled || mode === 'media') return;
  event.preventDefault();
  rightButton.setPointerCapture(event.pointerId);
  startHold(event.pointerId);
});
rightButton.addEventListener('pointerup', (event) => {
  if (hold?.pointerId !== event.pointerId) return;
  endHold(true);
});
rightButton.addEventListener('pointercancel', () => endHold());
rightButton.addEventListener('lostpointercapture', () => endHold());
rightButton.addEventListener('contextmenu', (event) => event.preventDefault());
rightButton.addEventListener('click', (event) => {
  if (mode === 'media') command({action: 'media', media: 'next'});
  else if (event.detail === 0 && !keyboardHolding) command({action: 'key', key: 'right'});
});
rightButton.addEventListener('keydown', (event) => {
  if (mode === 'media' || ![' ', 'Enter'].includes(event.key)) return;
  event.preventDefault();
  if (event.repeat) return;
  keyboardHolding = true;
  startHold();
});
rightButton.addEventListener('keyup', (event) => {
  if (!keyboardHolding || ![' ', 'Enter'].includes(event.key)) return;
  event.preventDefault();
  endHold(true);
  keyboardHolding = false;
});

async function flushVolume() {
  if (volumeSending) return;
  volumeSending = true;
  while (pendingVolume !== null && online) {
    const value = pendingVolume;
    pendingVolume = null;
    await command({action: 'volume', value});
  }
  volumeSending = false;
  if (!draggingVolume) setVolumeDisplay(state?.volume);
}

$('volume-slider').addEventListener('pointerdown', () => { draggingVolume = true; });
$('volume-slider').addEventListener('input', (event) => {
  setVolumeDisplay(Number(event.target.value) / 100);
  pendingVolume = Number(event.target.value) / 100;
  flushVolume();
});
const finishVolume = () => {
  draggingVolume = false;
  if (!volumeSending) setVolumeDisplay(state?.volume);
};
$('volume-slider').addEventListener('change', finishVolume);
window.addEventListener('pointerup', finishVolume);
window.addEventListener('pointercancel', finishVolume);

$('clear-notifications').addEventListener('click', async () => {
  endHold();
  notificationBusy = true;
  $('clear-label').textContent = '正在清理…';
  updateControls();
  const result = await command({action: 'clearNotifications'});
  if (result?.message) toast(result.message);
  notificationBusy = false;
  $('clear-label').textContent = '清除通知';
  updateControls();
});

$('connection-status').addEventListener('click', refresh);
$('frontmost-app-icon').addEventListener('error', () => {
  $('frontmost-app-icon').hidden = true;
  $('app-icon-fallback').removeAttribute('hidden');
});
window.addEventListener('blur', () => { endHold(); keyboardHolding = false; });
window.addEventListener('pagehide', () => endHold());
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { endHold(); keyboardHolding = false; }
  else refresh();
});
window.addEventListener('offline', () => { endHold(); setConnection(false); });
window.addEventListener('online', refresh);

async function initialize() {
  $('connection-status').classList.add('connecting');
  if (initialToken) {
    const token = initialToken;
    initialToken = null;
    await pair(token);
  } else await refresh();
  setInterval(refresh, 2500);
}
initialize();
