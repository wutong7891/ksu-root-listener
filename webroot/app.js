const CONTROL = '/data/adb/modules/ksu_app_watcher/bin/control.sh';
let callId = 0;
let allEvents = [];
const packageMap = new Map();
const $ = (id) => document.getElementById(id);
const quote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;

function rootExec(command, cwd = '/') {
  return new Promise((resolve, reject) => {
    if (!window.ksu || typeof window.ksu.exec !== 'function') return reject(new Error('请从 KernelSU 管理器打开 WebUI'));
    const callback = `__ksuCallback${++callId}`;
    window[callback] = (errno, stdout, stderr) => {
      delete window[callback];
      const result = { errno: Number(errno), stdout: stdout || '', stderr: stderr || '' };
      result.errno === 0 ? resolve(result) : reject(Object.assign(new Error(result.stderr || `退出码 ${result.errno}`), { result }));
    };
    try { window.ksu.exec(command, JSON.stringify({ cwd }), callback); }
    catch (error) { delete window[callback]; reject(error); }
  });
}

function toast(message) {
  const el = $('toast'); el.textContent = message; el.classList.add('show');
  clearTimeout(toast.timer); toast.timer = setTimeout(() => el.classList.remove('show'), 2400);
}

function parseStatus(text) {
  return Object.fromEntries(text.split('\n').filter((line) => line.includes('=')).map((line) => {
    const at = line.indexOf('='); return [line.slice(0, at), line.slice(at + 1)];
  }));
}

async function loadStatus() {
  try {
    const status = parseStatus((await rootExec(`${quote(CONTROL)} status`)).stdout);
    $('package').value = status.package || '';
    $('script').value = status.script || '';
    $('interval').value = status.interval || '2';
    $('cooldown').value = status.cooldown || '2';
    $('enabled').checked = status.enabled === '1';
    $('scriptInput').value = (await rootExec(`${quote(CONTROL)} get-preinput`)).stdout.replace(/\n$/, '');
    const events = (status.events || '').split(',');
    $('eventSu').checked = events.includes('sucompat');
    $('eventIoctl').checked = events.includes('ioctl_grant_root');
    $('eventExec').checked = events.includes('root_execve');
    const supported = status.sulog === 'supported';
    $('supportNotice').textContent = supported ? '✓ 当前内核支持 sulog Root监听' : `⚠ sulog 状态：${status.sulog || '不可用'}；需要使用你的定制 KernelSU 内核与 ksud`;
    $('supportNotice').classList.toggle('ok', supported);
    const running = status.watcher === 'running';
    $('watcherBadge').textContent = running ? (status.enabled === '1' ? 'Root监听中' : '服务待命') : '服务未运行';
    $('watcherBadge').classList.toggle('on', running && status.enabled === '1');
  } catch (error) { $('watcherBadge').textContent = '连接失败'; toast(error.message); }
}

async function saveConfig() {
  const events = [
    $('eventSu').checked && 'sucompat',
    $('eventIoctl').checked && 'ioctl_grant_root',
    $('eventExec').checked && 'root_execve',
  ].filter(Boolean).join(',');
  const args = [$('package').value.trim(), $('script').value.trim(), $('interval').value, $('enabled').checked ? '1' : '0', events, $('cooldown').value];
  try {
    await rootExec(`${quote(CONTROL)} set-preinput ${quote($('scriptInput').value)} && ${quote(CONTROL)} configure ${args.map(quote).join(' ')} && ${quote(CONTROL)} restart`);
    toast('配置已保存'); await loadStatus();
  } catch (error) { toast(error.message); }
}

async function runControl(action, target = 'terminal') {
  $(target).textContent = '执行中…';
  try {
    const result = await rootExec(`${quote(CONTROL)} ${action}`);
    $(target).textContent = [result.stdout, result.stderr].filter(Boolean).join('\n') || '执行成功（无输出）'; toast('执行完成');
  } catch (error) {
    $(target).textContent = error.result ? [error.result.stdout, error.result.stderr].filter(Boolean).join('\n') : error.message; toast('执行失败');
  }
}

function parentPath(path) {
  const clean = path.replace(/\/+$/, '');
  if (!clean || clean === '/') return '/';
  return clean.slice(0, clean.lastIndexOf('/')) || '/';
}

async function browse(path) {
  $('files').innerHTML = '<span class="hint">读取中…</span>';
  try {
    const normalized = path.startsWith('/') ? path : `/${path}`;
    const { stdout } = await rootExec(`${quote(CONTROL)} list-dir ${quote(normalized)}`);
    $('path').value = normalized;
    const rows = stdout.split('\n').filter(Boolean).map((line) => {
      const at = line.indexOf('\t'); return { kind: line.slice(0, at), path: line.slice(at + 1) };
    });
    $('files').innerHTML = '';
    if (!rows.length) $('files').innerHTML = '<span class="hint">目录为空或无法读取</span>';
    rows.forEach((entry) => {
      const button = document.createElement('button');
      button.className = 'fileRow';
      button.textContent = `${entry.kind === 'd' ? '📁' : '📄'} ${entry.path.split('/').pop()}`;
      button.title = entry.path;
      button.addEventListener('click', () => {
        if (entry.kind === 'd') browse(entry.path);
        else { $('script').value = entry.path; toast('已填入脚本路径'); window.scrollTo({ top: 0, behavior: 'smooth' }); }
      });
      $('files').appendChild(button);
    });
  } catch (error) { $('files').textContent = error.message; }
}

async function executeConsole() {
  const command = $('command').value; localStorage.setItem('ksu-preinput', command);
  $('terminal').textContent = `$ cd /\n# ${command}\n\n执行中…`;
  try {
    const result = await rootExec(command, '/');
    $('terminal').textContent = `$ cd /\n# ${command}\n\n${[result.stdout, result.stderr].filter(Boolean).join('\n') || '完成（无输出）'}`;
  } catch (error) {
    const detail = error.result ? [error.result.stdout, error.result.stderr].filter(Boolean).join('\n') : error.message;
    $('terminal').textContent = `$ cd /\n# ${command}\n\n${detail}`;
  }
}

function decodeField(value) {
  if (!value.startsWith('"')) return value;
  return value.slice(1, -1)
    .replace(/\\n/g, '\n').replace(/\\r/g, '\r').replace(/\\t/g, '\t')
    .replace(/\\x([0-9a-fA-F]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\"/g, '"').replace(/\\\\/g, '\\');
}

function parseEventLine(raw) {
  const fields = {};
  const regex = /([A-Za-z0-9_]+)=("(?:\\.|[^"])*"|[^\s]+)/g;
  let match;
  while ((match = regex.exec(raw))) fields[match[1]] = decodeField(match[2]);
  return { raw, fields, type: fields.type || 'unknown' };
}

async function loadPackages() {
  try {
    const { stdout } = await rootExec(`${quote(CONTROL)} packages`);
    stdout.split('\n').forEach((line) => {
      const match = line.match(/^package:(.+) uid:(\d+)$/);
      if (match) {
        const appId = Number(match[2]) % 100000;
        if (!packageMap.has(appId)) packageMap.set(appId, match[1]);
      }
    });
  } catch (_) { /* UID 仍可显示 */ }
}

function eventLabel(type) {
  return ({
    sucompat: '经典 SU', ioctl_grant_root: 'Root 授权', root_execve: 'Root execve',
    daemon_start: '守护进程启动', daemon_restart: '守护进程重启', dropped: '丢失事件',
  })[type] || type;
}

function renderEvents() {
  const root = $('events');
  const query = $('eventSearch').value.trim().toLowerCase();
  const filters = new Set([...document.querySelectorAll('[data-event-filter]:checked')].map((el) => el.dataset.eventFilter));
  const visible = allEvents.filter((event) => {
    const normalizedType = event.type.startsWith('daemon_') ? 'daemon_start' : event.type;
    if (!filters.has(normalizedType) && !['dropped', 'unknown'].includes(event.type)) return false;
    const uid = Number(event.fields.uid || -1);
    const pkg = packageMap.get(uid % 100000) || '';
    return !query || `${event.raw} ${pkg}`.toLowerCase().includes(query);
  }).reverse();

  root.innerHTML = '';
  if (!visible.length) { root.innerHTML = '<span class="hint">没有符合条件的 Root 事件</span>'; return; }
  visible.forEach((event) => {
    const uid = Number(event.fields.uid || -1);
    const pkg = packageMap.get(uid % 100000) || (uid >= 0 ? `UID ${uid}` : 'KernelSU');
    const card = document.createElement('div'); card.className = 'eventCard';
    const icon = document.createElement('img'); icon.className = 'eventIcon'; icon.alt = '';
    if (pkg.includes('.')) icon.src = `ksu://icon/${pkg}`; else icon.style.visibility = 'hidden';
    const content = document.createElement('div');
    const title = document.createElement('div'); title.className = 'eventTitle';
    const app = document.createElement('span'); app.textContent = pkg;
    const type = document.createElement('span'); type.className = 'eventType'; type.textContent = eventLabel(event.type);
    title.append(app, type);
    const command = document.createElement('div'); command.className = 'eventCommand';
    command.textContent = event.fields.argv || event.fields.file || event.fields.comm || event.type;
    const meta = document.createElement('div'); meta.className = 'eventMeta';
    meta.textContent = `UID ${event.fields.uid || '-'} · PID ${event.fields.pid || '-'} · ${event.fields.comm || '-'} · seq ${event.fields.seq || '-'}`;
    content.append(title, command, meta); card.append(icon, content);
    const raw = document.createElement('pre'); raw.className = 'eventRaw'; raw.textContent = event.raw; raw.hidden = true;
    card.appendChild(raw); card.addEventListener('click', () => { raw.hidden = !raw.hidden; }); root.appendChild(card);
  });
}

async function refreshLogs() {
  try {
    await loadPackages();
    const output = (await rootExec(`${quote(CONTROL)} root-log 500`)).stdout;
    allEvents = output.split('\n').filter((line) => line.includes('type=')).map(parseEventLine);
    renderEvents();
  } catch (e) { $('events').textContent = e.message; }
  try { $('log').textContent = (await rootExec(`${quote(CONTROL)} log 150`)).stdout || '暂无日志'; } catch (e) { $('log').textContent = e.message; }
}

$('save').addEventListener('click', saveConfig);
$('openApp').addEventListener('click', () => runControl('open'));
$('runScript').addEventListener('click', () => runControl('run'));
$('execute').addEventListener('click', executeConsole);
$('showRoot').addEventListener('click', () => { $('command').value = 'pwd && ls -la /'; executeConsole(); });
$('rootDir').addEventListener('click', () => browse('/'));
$('upDir').addEventListener('click', () => browse(parentPath($('path').value)));
$('goDir').addEventListener('click', () => browse($('path').value.trim()));
$('path').addEventListener('keydown', (event) => { if (event.key === 'Enter') browse($('path').value.trim()); });
$('refreshRootLog').addEventListener('click', refreshLogs);
$('clearRootLog').addEventListener('click', async () => { await rootExec(`${quote(CONTROL)} clear-root-log`); allEvents = []; renderEvents(); toast('Root监听日志已清空'); });
$('refreshLog').addEventListener('click', refreshLogs);
$('clearLog').addEventListener('click', async () => { await runControl('clear-log', 'log'); await refreshLogs(); });
document.querySelectorAll('[data-command]').forEach((button) => button.addEventListener('click', () => { $('command').value = button.dataset.command; $('command').focus(); }));
document.querySelectorAll('[data-event-filter]').forEach((input) => input.addEventListener('change', renderEvents));
$('eventSearch').addEventListener('input', renderEvents);

$('command').value = localStorage.getItem('ksu-preinput') || 'pwd && ls -la /';
loadStatus(); browse('/'); refreshLogs();

