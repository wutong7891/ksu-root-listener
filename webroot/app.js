const CONTROL = '/data/adb/modules/ksu_app_watcher/bin/control.sh';
let callId = 0;
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
    $('activationCode').value = (await rootExec(`${quote(CONTROL)} get-expected`)).stdout.replace(/\n$/, '');
    const foreground = status.foreground || '未识别';
    const keyboard = status.keyboard === 'visible' ? '已弹出' : '已收起';
    $('supportNotice').textContent = `当前前台：${foreground} · 键盘：${keyboard}`;
    $('supportNotice').classList.add('ok');
    const running = status.watcher === 'running';
    $('watcherBadge').textContent = running ? (status.enabled === '1' ? '键盘监听中' : '服务待命') : '服务未运行';
    $('watcherBadge').classList.toggle('on', running && status.enabled === '1');
  } catch (error) { $('watcherBadge').textContent = '连接失败'; toast(error.message); }
}

async function saveConfig() {
  const events = 'foreground_or_input_match';
  const args = [$('package').value.trim(), $('script').value.trim(), $('interval').value, $('enabled').checked ? '1' : '0', events, $('cooldown').value];
  const activationCode = $('activationCode').value.trim();
  if (activationCode && !/^\d+$/.test(activationCode)) { toast('激活内容只能填写数字 0-9'); return; }
  try {
    await rootExec(`${quote(CONTROL)} set-expected ${quote(activationCode)} && ${quote(CONTROL)} set-preinput ${quote($('scriptInput').value)} && ${quote(CONTROL)} configure ${args.map(quote).join(' ')}`);
    toast(activationCode ? '配置已保存：输入该数字后立即执行' : '配置已保存：使用 v11 前台触发'); await loadStatus();
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

async function runScriptWithInput() {
  $('terminal').textContent = '正在保存预输入并执行脚本…';
  try {
    const input = $('scriptInput').value;
    const result = await rootExec(`${quote(CONTROL)} set-preinput ${quote(input)} && ${quote(CONTROL)} run`);
    $('terminal').textContent = [result.stdout, result.stderr].filter(Boolean).join('\n') || '执行成功（无输出）';
    toast('预输入已发送，脚本执行完成');
  } catch (error) {
    $('terminal').textContent = error.result
      ? [error.result.stdout, error.result.stderr].filter(Boolean).join('\n')
      : error.message;
    toast('脚本执行失败');
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

async function refreshLogs() {
  try { $('log').textContent = (await rootExec(`${quote(CONTROL)} log 150`)).stdout || '暂无日志'; } catch (e) { $('log').textContent = e.message; }
}

$('save').addEventListener('click', saveConfig);
$('openApp').addEventListener('click', () => runControl('open'));
$('checkInput').addEventListener('click', () => runControl('check-input'));
$('runScript').addEventListener('click', runScriptWithInput);
$('execute').addEventListener('click', executeConsole);
$('showRoot').addEventListener('click', () => { $('command').value = 'pwd && ls -la /'; executeConsole(); });
$('rootDir').addEventListener('click', () => browse('/'));
$('upDir').addEventListener('click', () => browse(parentPath($('path').value)));
$('goDir').addEventListener('click', () => browse($('path').value.trim()));
$('path').addEventListener('keydown', (event) => { if (event.key === 'Enter') browse($('path').value.trim()); });
$('refreshLog').addEventListener('click', refreshLogs);
$('clearLog').addEventListener('click', async () => { await runControl('clear-log', 'log'); await refreshLogs(); });
document.querySelectorAll('[data-command]').forEach((button) => button.addEventListener('click', () => { $('command').value = button.dataset.command; $('command').focus(); }));

$('command').value = localStorage.getItem('ksu-preinput') || 'pwd && ls -la /';
loadStatus(); browse('/'); refreshLogs();

