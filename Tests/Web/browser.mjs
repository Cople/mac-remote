// End-to-end checks of the actual web assets, using an isolated headless Chrome profile.
// The HTTP fixture records commands; it never controls the host Mac.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdtemp, mkdir, rm, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

const root = fileURLToPath(new URL('../../', import.meta.url));
const webRoot = path.join(root, 'Sources/MacRemote/Web');
const output = path.join(root, '.build/web-check');
await mkdir(output, {recursive: true});
const profile = await mkdtemp(path.join(output, 'chrome-'));
const commands = [];
const appIcon = 'data:image/png;base64,' + (process.env.MAC_REMOTE_TEST_APP_ICON
  ? (await readFile(process.env.MAC_REMOTE_TEST_APP_ICON)).toString('base64')
  : 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aYZkAAAAASUVORK5CYII=');
const state = {name: '客厅的 MacBook Pro', version: '1.0.0', accessibility: true,
  volume: .65, muted: false, volumeControllable: true, frontmostApp: 'IINA', frontmostAppIcon: appIcon, holding: false};
let holdDelay = 0;
let failure = null;
let pairingRequired = true;
let sessionGeneration = 0;
const pairingCode = '012345';
const pairingAttempts = [];
const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  const reply = (status, data, headers = {}) => {
    response.writeHead(status, {'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers});
    response.end(JSON.stringify(data));
  };
  const session = `macremote=fixture-${sessionGeneration}`;
  const validSession = request.headers.cookie?.split(';').some((cookie) => cookie.trim() === session);
  const sessionHeader = {'Set-Cookie': session + '; Path=/; HttpOnly; SameSite=Strict'};
  if (url.pathname === '/api/pair') {
    let body = '';
    for await (const chunk of request) body += chunk;
    const payload = JSON.parse(body);
    pairingAttempts.push(payload.token);
    if (pairingRequired && payload.token !== pairingCode) return reply(401, {error: '配对码不正确或已失效'});
    return reply(200, state, sessionHeader);
  }
  if (url.pathname === '/api/state') {
    if (!validSession && pairingRequired) return reply(401, {error: '请输入 6 位配对码'});
    return reply(200, state, validSession ? {} : sessionHeader);
  }
  if (url.pathname === '/api/command') {
    if (!validSession) return reply(401, {error: '连接已失效'});
    let body = '';
    for await (const chunk of request) body += chunk;
    const command = JSON.parse(body);
    commands.push(command);
    if (failure) return reply(failure.status, {error: failure.message});
    if (command.action === 'holdStart') { if (holdDelay) await delay(holdDelay); state.holding = true; }
    if (command.action === 'holdEnd') state.holding = false;
    if (command.action === 'volume') state.volume = command.value;
    if (command.action === 'volumeStep') state.volume = Math.max(0, Math.min(1, state.volume + command.value));
    if (command.action === 'mute') state.muted = !state.muted;
    return reply(200, {...state, message: command.action === 'clearNotifications' ? '已清除通知' : undefined});
  }
  const files = {'/': ['index.html', 'text/html'], '/app.js': ['app.js', 'text/javascript'],
    '/app.css': ['app.css', 'text/css'], '/icon.svg': ['icon.svg', 'image/svg+xml'],
    '/manifest.webmanifest': ['manifest.webmanifest', 'application/manifest+json'],
    '/icons/icon-192.png': ['icons/icon-192.png', 'image/png'],
    '/icons/icon-512.png': ['icons/icon-512.png', 'image/png'],
    '/icons/icon-maskable-512.png': ['icons/icon-maskable-512.png', 'image/png'],
    '/icons/apple-touch-icon.png': ['icons/apple-touch-icon.png', 'image/png']};
  if (!files[url.pathname]) { response.writeHead(404); return response.end(); }
  const [file, type] = files[url.pathname];
  response.writeHead(200, {'Content-Type': type + '; charset=utf-8',
    'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"});
  response.end(await readFile(path.join(webRoot, file)));
});
await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
const base = `http://127.0.0.1:${server.address().port}`;
const chrome = spawn(process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
  '--disable-default-apps', '--disable-sync', '--disable-extensions', '--password-store=basic', '--use-mock-keychain', 'about:blank'
], {stdio: ['ignore', 'ignore', 'pipe']});
let chromeError = '';
chrome.stderr.on('data', (data) => { chromeError += data.toString(); });
let socket;
try {
  let portFile;
  for (let index = 0; index < 160; index++) {
    try { portFile = await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8'); break; }
    catch { if (chrome.exitCode !== null) throw new Error(`Chrome exited: ${chromeError}`); await delay(50); }
  }
  assert.ok(portFile, `Chrome debugger did not start: ${chromeError}`);
  const debugPort = portFile.split('\n')[0];
  const target = await (await fetch(`http://127.0.0.1:${debugPort}/json/new?about:blank`, {method: 'PUT'})).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, {once: true}); socket.addEventListener('error', reject, {once: true}); });
  let sequence = 0;
  const pending = new Map();
  const runtimeErrors = [];
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const item = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) item.reject(new Error(JSON.stringify(message.error))); else item.resolve(message.result);
    } else if (message.method === 'Runtime.exceptionThrown') runtimeErrors.push(message.params.exceptionDetails);
  });
  const cdp = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
  const evaluate = async (expression) => {
    const result = await cdp('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true});
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const until = async (expression, label) => {
    for (let index = 0; index < 100; index++) {
      if (await evaluate(expression)) return;
      await delay(50);
    }
    throw new Error(`Timed out: ${label}`);
  };
  const click = async (id) => { await evaluate(`document.getElementById(${JSON.stringify(id)}).click()`); await delay(100); };
  const screenshot = async (name) => {
    const shot = await cdp('Page.captureScreenshot', {format: 'png', captureBeyondViewport: true});
    await writeFile(path.join(output, name), Buffer.from(shot.data, 'base64'));
  };
  const checkRingTargets = async () => {
    const hits = await evaluate(`(() => {
      const rect = document.getElementById('remote-pad').getBoundingClientRect();
      const cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2;
      const samples = [];
      const groups = [['up', [-130, -90, -50]], ['right', [-40, 0, 40]], ['down', [50, 90, 130]], ['left', [140, 180, 220]]];
      for (const [name, angles] of groups) {
        for (const angle of angles) {
          for (const radius of [65, rect.width / 2 - 8]) {
            const radians = angle * Math.PI / 180;
            const target = document.elementFromPoint(cx + Math.cos(radians) * radius, cy + Math.sin(radians) * radius);
            samples.push({expected: 'pad-' + name, actual: target?.closest('button')?.id, angle, radius});
          }
        }
      }
      samples.push({expected: 'pad-play', actual: document.elementFromPoint(cx, cy)?.closest('button')?.id});
      samples.push({expected: null, actual: document.elementFromPoint(rect.x + 7, rect.y + 7)?.closest('button')?.id ?? null});
      return samples;
    })()`);
    for (const hit of hits) assert.equal(hit.actual, hit.expected, `Ring target at ${JSON.stringify(hit)}`);
  };
  await cdp('Page.enable');
  await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', {width: 390, height: 844, deviceScaleFactor: 2, mobile: true});
  await cdp('Page.navigate', {url: `${base}/#token=${pairingCode}`});
  await until("document.getElementById('connection-label')?.textContent === '已连接'", 'pairing');
  const shortcutLabel = (key) => evaluate(`document.querySelector('[data-key="${key}"] kbd').textContent`);
  state.shortcutLabels = {fullscreen: 'fn F'};
  await evaluate('refresh()');
  assert.equal(await shortcutLabel('fullscreen'), 'fn F');
  state.shortcutLabels = {fullscreen: '⌘ F'};
  await evaluate('refresh()');
  assert.equal(await shortcutLabel('fullscreen'), '⌘ F');
  state.shortcutLabels = {previous: '⌥ ←', next: '⌥ →', fullscreen: 'F'};
  await evaluate('refresh()');
  assert.equal(await shortcutLabel('previous'), '⌥ ←');
  assert.equal(await shortcutLabel('next'), '⌥ →');
  state.shortcutLabels = {previous: '⇧ ←', next: '⇧ →', fullscreen: 'F'};
  await evaluate('refresh()');
  assert.equal(await shortcutLabel('previous'), '⇧ ←');
  assert.equal(await shortcutLabel('next'), '⇧ →');
  delete state.shortcutLabels;
  await evaluate('refresh()');
  assert.equal(await shortcutLabel('previous'), '[');
  assert.equal(await shortcutLabel('next'), ']');
  assert.equal(await shortcutLabel('fullscreen'), 'F');
  const appManifest = await cdp('Page.getAppManifest');
  assert.deepEqual(appManifest.errors, [], 'The browser can parse the linked web manifest');
  const manifest = JSON.parse(appManifest.data);
  assert.equal(new URL(manifest.start_url, appManifest.url).href, base + '/');
  assert.equal(manifest.display, 'standalone');
  for (const icon of manifest.icons) {
    const size = await evaluate(`new Promise((resolve, reject) => {
      const icon = new Image(); icon.onload = () => resolve(icon.naturalWidth + 'x' + icon.naturalHeight);
      icon.onerror = reject; icon.src = ${JSON.stringify(icon.src)};
    })`);
    assert.equal(size, icon.sizes, 'The manifest icon exists at its declared size');
  }
  assert.equal(await evaluate('location.hash'), '');
  assert.equal(await evaluate('document.cookie'), '');
  assert.ok(await evaluate('document.documentElement.scrollWidth <= innerWidth'), 'No horizontal overflow on a phone');
  await checkRingTargets();
  await until("!document.getElementById('frontmost-app-icon').hidden && document.getElementById('frontmost-app-icon').naturalWidth > 0", 'current app icon');
  assert.equal(await evaluate("getComputedStyle(document.getElementById('app-icon-fallback')).display"), 'none');
  state.frontmostApp = '测试应用';
  state.frontmostAppIcon = undefined;
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('frontmost-app-icon').hidden"), true);
  assert.notEqual(await evaluate("getComputedStyle(document.getElementById('app-icon-fallback')).display"), 'none');
  assert.equal(await evaluate("document.getElementById('frontmost-app').textContent"), '测试应用');
  assert.equal(await evaluate("document.getElementById('device-name')"), null);
  state.frontmostWindowTitle = '示例视频 <第一集> ' + '长标题'.repeat(60);
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('frontmost-window-title').textContent"), state.frontmostWindowTitle);
  assert.equal(await evaluate("document.getElementById('frontmost-window-title').hidden"), false);
  assert.equal(await evaluate("getComputedStyle(document.getElementById('frontmost-window-title')).textOverflow"), 'ellipsis');
  assert.ok(await evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Long window titles stay within the mobile viewport');
  delete state.frontmostWindowTitle;
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('frontmost-window-title').hidden"), true);
  assert.equal(await evaluate("document.getElementById('frontmost-window-title').textContent"), '');
  state.frontmostAppIcon = 'https://example.com/icon.png';
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('frontmost-app-icon').hasAttribute('src')"), false);
  state.frontmostApp = 'IINA';
  state.frontmostAppIcon = appIcon;
  state.frontmostWindowTitle = '示例视频.mp4';
  await evaluate('refresh()');
  await until("!document.getElementById('frontmost-app-icon').hidden && document.getElementById('frontmost-app-icon').naturalWidth > 0", 'restored app icon');
  await evaluate("document.getElementById('toast').hidden = true");
  await screenshot('mobile.png');
  await click('pad-play');
  assert.deepEqual(commands.at(-1), {action: 'key', key: 'space'});
  await click('pad-left');
  assert.deepEqual(commands.at(-1), {action: 'key', key: 'left'});
  await evaluate("document.querySelector('[data-key=danmaku]').click(); commandQueue");
  assert.deepEqual(commands.at(-1), {action: 'key', key: 'danmaku'});
  await click('volume-up');
  assert.equal(Math.round(state.volume * 100), 75);
  await click('mute-button');
  assert.equal(state.muted, true);
  assert.equal(await evaluate("document.getElementById('mute-label').textContent"), '取消静音');
  await evaluate("document.getElementById('volume-slider').value = 38; document.getElementById('volume-slider').dispatchEvent(new Event('input', {bubbles:true}))");
  await until("document.getElementById('volume-value').textContent === '38%'", 'volume slider');
  assert.equal(state.volume, .38);

  // Exercise actual pointer input, including a release before holdStart's response arrives.
  const right = await evaluate("JSON.stringify((() => {const r=document.querySelector('#pad-right .pad-content').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})())");
  const point = JSON.parse(right);
  const pointer = (type) => cdp('Input.dispatchMouseEvent', {type, x: point.x, y: point.y, button: 'left', clickCount: 1});
  let mark = commands.length;
  await pointer('mousePressed');
  await delay(80);
  await pointer('mouseReleased');
  await delay(150);
  assert.deepEqual(commands.slice(mark), [{action: 'key', key: 'right'}], 'A short tap sends one right arrow');
  holdDelay = 200;
  mark = commands.length;
  await pointer('mousePressed');
  await delay(390);
  await pointer('mouseReleased');
  await delay(450);
  assert.deepEqual(commands.slice(mark), [{action: 'holdStart'}, {action: 'holdEnd'}], 'Early release is ordered after key-down');
  assert.equal(state.holding, false);
  holdDelay = 0;
  mark = commands.length;
  await pointer('mousePressed');
  await delay(1250);
  await pointer('mouseReleased');
  await delay(200);
  assert.ok(commands.slice(mark).some((command) => command.action === 'holdHeartbeat'));
  assert.equal(commands.at(-1).action, 'holdEnd');

  await click('mode-media');
  await click('pad-play');
  assert.deepEqual(commands.at(-1), {action: 'media', media: 'playPause'});
  await click('pad-right');
  assert.deepEqual(commands.at(-1), {action: 'media', media: 'next'});
  await click('clear-notifications');
  assert.equal(commands.at(-1).action, 'clearNotifications');

  state.accessibility = false;
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('pad-play').disabled"), true);
  assert.equal(await evaluate("document.getElementById('volume-up').disabled"), false);
  assert.equal(await evaluate("document.getElementById('permission-banner').hidden"), false);
  state.accessibility = true;
  state.volumeControllable = false;
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('volume-slider').disabled"), true);
  state.volumeControllable = true;
  await evaluate('refresh()');
  await click('mode-keyboard');
  await cdp('Emulation.setDeviceMetricsOverride', {width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false});
  await checkRingTargets();
  await evaluate("document.getElementById('toast').hidden = true");
  await screenshot('desktop.png');
  await cdp('Emulation.setDeviceMetricsOverride', {width: 320, height: 844, deviceScaleFactor: 2, mobile: true});
  assert.ok(await evaluate('document.documentElement.scrollWidth <= innerWidth'), 'No horizontal overflow with five shortcuts on a small phone');
  await checkRingTargets();

  // Disabling the key permits direct access; enabling it revokes every open session.
  pairingRequired = false;
  sessionGeneration++;
  await cdp('Page.navigate', {url: base + '/'});
  await until("document.getElementById('connection-label')?.textContent === '已连接'", 'keyless direct access');
  assert.equal(await evaluate("document.getElementById('pairing-overlay').hidden"), true);
  pairingRequired = true;
  sessionGeneration++;
  await evaluate('refresh()');
  assert.equal(await evaluate("document.getElementById('pairing-overlay').hidden"), false);
  const attemptsBeforeInvalidInput = pairingAttempts.length;
  await evaluate("document.getElementById('pairing-token').value = '12345'; document.getElementById('pairing-form').requestSubmit()");
  await delay(100);
  assert.equal(pairingAttempts.length, attemptsBeforeInvalidInput, 'Reject codes that are not exactly six digits');
  await evaluate("document.getElementById('pairing-token').value = '012345'; document.getElementById('pairing-form').requestSubmit()");
  await until("document.getElementById('pairing-overlay').hidden", 'manual numeric pairing with a leading zero');
  assert.equal(pairingAttempts.at(-1), '012345');
  sessionGeneration++;
  await evaluate('refresh()');
  await evaluate(`document.getElementById('pairing-token').value = ${JSON.stringify(base + '/#token=012345')}; document.getElementById('pairing-form').requestSubmit()`);
  await until("document.getElementById('pairing-overlay').hidden", 'pairing by pasted link');
  assert.equal(pairingAttempts.at(-1), '012345');

  failure = {status: 401, message: '配对已重置，请重新扫码'};
  await click('pad-play');
  assert.equal(await evaluate("document.getElementById('pairing-overlay').hidden"), false);
  assert.equal(await evaluate("document.getElementById('pad-play').disabled"), true);
  assert.deepEqual(runtimeErrors, [], 'No uncaught browser exceptions');
  console.log('Web checks passed: four annular hit regions on phone/desktop/small screens, hold safety, pairing modes, app icons and media controls.');
  console.log(`Screenshots: ${output}`);
} finally {
  socket?.close();
  chrome.kill('SIGTERM');
  await new Promise((resolve) => { if (chrome.exitCode !== null) resolve(); else { chrome.once('exit', resolve); setTimeout(() => { chrome.kill('SIGKILL'); resolve(); }, 2500).unref(); } });
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  await rm(profile, {recursive: true, force: true});
}
