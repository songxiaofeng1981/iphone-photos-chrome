'use strict';
const HOST_NAME = 'com.song.iphone_photos';
const FIRST_PAGE = 30;        // 首屏只列最新 30 项
const NEXT_PAGE = 60;         // 往下滚再取下一批
const THUMB_CONCURRENCY = 4;  // 同时最多请求几张缩略图
const LOG_PATH = '~/Library/Logs/iPhonePhotosHelper.log';

const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = n => String(n).padStart(2, '0');
const dayKey = t => { const d = new Date(t); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const hhmm = t => { const d = new Date(t); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const mb = b => (b / 1e6).toFixed(b >= 1e7 ? 0 : 1);
const WEEK = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
function dayLabel(key) {
  const [y, m, d] = key.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const diff = Math.round((today - date) / 864e5);
  const sub = `${m}月${d}日 ${WEEK[date.getDay()]}`;
  if (diff === 0) return ['今天', sub];
  if (diff === 1) return ['昨天', sub];
  return [y === today.getFullYear() ? `${m}月${d}日` : `${y}年${m}月${d}日`, WEEK[date.getDay()]];
}

/* ------------------------------------------------------------ native host */
const host = {
  port: null, rid: 0, pending: new Map(), onEvent: null, onDisconnect: null,
  connect() {
    this.port = chrome.runtime.connectNative(HOST_NAME);
    this.port.onMessage.addListener(m => {
      if (m.event) { this.onEvent && this.onEvent(m); return; }
      const p = this.pending.get(m.rid);
      if (!p) return;
      this.pending.delete(m.rid);
      if (m.ok) p.resolve(m.result);
      else p.reject(Object.assign(new Error(m.error || '未知错误'), { code: m.code }));
    });
    this.port.onDisconnect.addListener(() => {
      const err = (chrome.runtime.lastError && chrome.runtime.lastError.message) || '';
      this.port = null;
      for (const p of this.pending.values()) p.reject(Object.assign(new Error('读取助手已断开'), { code: 'host_gone' }));
      this.pending.clear();
      this.onDisconnect && this.onDisconnect(err);
    });
  },
  call(cmd, args = {}) {
    if (!this.port) return Promise.reject(Object.assign(new Error('读取助手未连接'), { code: 'host_gone' }));
    const rid = ++this.rid;
    return new Promise((resolve, reject) => {
      this.pending.set(rid, { resolve, reject });
      this.port.postMessage({ rid, cmd, ...args });
    });
  }
};

/* ------------------------------------------------------------ state */
const S = {
  phase: 'starting', device: null, mode: 'today',
  items: [], byId: new Map(), cursor: null, done: false, loading: false, sawOlder: false, gen: 0,
  sel: new Set(), last: null, lastTap: {},
  thumbs: new Map(), meta: new Map(), requested: new Set(), visible: new Set(), queue: [], active: 0,
  groups: new Map(), t0: 0, firstShown: false, exporting: false, pvId: null, previews: new Map(), pollTimer: null,
};
const today = () => dayKey(Date.now());
const shown = it => S.mode === 'all' || dayKey(it.t) === today();
const shownOrder = () => S.items.filter(shown).map(i => i.id);

/* ------------------------------------------------------------ status screens */
function setPhase(phase, info = {}) {
  S.phase = phase;
  const scr = $('#screen'), ready = phase === 'ready';
  $('#wall').hidden = !ready; $('#tray').hidden = !ready; $('#modes').hidden = !ready; $('#refresh').hidden = !ready;
  scr.hidden = ready;
  if (!ready) { $('#metric').textContent = ''; closePv(); }
  const sub = $('#devSub');
  const screens = {
    starting: () => { sub.textContent = '正在启动读取助手'; return `<div class="card"><p class="wait"><span class="pulse"></span>正在启动读取助手…</p></div>`; },
    install: () => { sub.textContent = '还没装读取助手'; return `<div class="card">
      <h2>还差一步：安装读取助手</h2>
      <p>插件需要一个 Mac 上的小程序通过数据线读照片。只装一次，平时不在后台运行。</p>
      <ol><li>打开“终端”，进入解压后的文件夹</li><li>运行 <code>bash install.sh</code></li><li>装好后点下面的按钮</li></ol>
      ${info.err ? `<p class="err">Chrome 返回：${esc(info.err)}</p>` : ''}
      <button class="primary" data-act="retry">重新检测</button></div>`; },
    host_error: () => { sub.textContent = '读取助手出错'; return `<div class="card">
      <h2>读取助手意外退出</h2><p class="err">${esc(info.err || '没有错误信息')}</p>
      <p>日志在 <code>${LOG_PATH}</code></p>
      <button class="primary" data-act="retry">重新启动</button></div>`; },
    nodevice: () => { sub.textContent = '未连接'; return `<div class="card"><div class="bigphone"></div>
      <h2>用数据线连接 iPhone</h2>
      <ol><li>用数据线把 iPhone 接到这台 Mac</li><li>第一次连接时，在 iPhone 上点“信任”并输入密码</li><li>保持手机解锁，照片会自动出现</li></ol>
      <p class="wait"><span class="pulse"></span>正在等待设备</p></div>`; },
    pairing: () => { sub.textContent = '等待信任'; return `<div class="card"><div class="bigphone"></div>
      <h2>在 iPhone 上点“信任”</h2><p>手机上会弹出“要信任此电脑吗”，点“信任”并输入锁屏密码。只需要做一次。</p>
      <p class="wait"><span class="pulse"></span>等待确认</p></div>`; },
    locked: () => { sub.textContent = '手机已锁定'; return `<div class="card"><div class="bigphone locked"></div>
      <h2>请解锁 iPhone</h2><p>解锁后会自动继续。</p><p class="wait"><span class="pulse"></span>等待解锁</p></div>`; },
    denied: () => { sub.textContent = '未被信任'; return `<div class="card"><div class="bigphone"></div>
      <h2>iPhone 上点了“不信任”</h2>
      <p>拔掉数据线再插上，手机会再问一次。如果不再弹出，到 iPhone 的 设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私，然后重新插线。</p>
      <p class="wait"><span class="pulse"></span>等待重新连接</p></div>`; },
    error: () => { sub.textContent = '连接出错'; return `<div class="card"><h2>连接 iPhone 时出错</h2>
      <p class="err">${esc(info.message || '')}</p><p>会自动重试。日志在 <code>${LOG_PATH}</code></p></div>`; },
  };
  if (!ready) scr.innerHTML = (screens[phase] || screens.error)();
}
$('#screen').addEventListener('click', e => { if (e.target.closest('[data-act="retry"]')) start(); });

/* ------------------------------------------------------------ connection + polling */
function start() {
  clearTimeout(S.pollTimer);
  setPhase('starting');
  host.onDisconnect = err => {
    clearTimeout(S.pollTimer);
    if (/not found|not registered|forbidden/i.test(err)) setPhase('install', { err });
    else setPhase('host_error', { err });
  };
  host.onEvent = onHostEvent;
  try { host.connect(); } catch (e) { setPhase('install', { err: String(e) }); return; }
  host.call('hello').then(r => { S.helperVersion = r.version; poll(); }).catch(() => {});
}

function poll() {
  clearTimeout(S.pollTimer);
  host.call('status').then(st => {
    if (st.state === 'ready') {
      const changed = !S.device || S.device.serial !== st.serial;
      S.device = st;
      if (S.phase !== 'ready' || changed) enterReady();
    } else {
      if (S.phase === 'ready') resetWall();
      S.device = null;
      setPhase(st.state, st);
    }
    S.pollTimer = setTimeout(poll, S.phase === 'ready' ? 4000 : 1500);
  }).catch(e => {
    if (e.code !== 'host_gone') S.pollTimer = setTimeout(poll, 2000);
  });
}

function onDeviceLost() {
  resetWall();
  S.device = null;
  setPhase('nodevice');
  poll();
}

/* ------------------------------------------------------------ list + paging */
function resetWall() {
  S.gen++;
  S.items = []; S.byId.clear(); S.cursor = null; S.done = false; S.loading = false; S.sawOlder = false;
  S.queue = []; S.requested.clear(); S.visible.clear(); S.groups.clear();
  S.firstShown = false; S.last = null;
  for (const u of S.thumbs.values()) URL.revokeObjectURL(u);
  for (const u of S.previews.values()) URL.revokeObjectURL(u);
  S.thumbs.clear(); S.meta.clear(); S.previews.clear(); S.sel.clear();
  $('#groups').innerHTML = ''; $('#endnote').innerHTML = '';
}

function enterReady() {
  resetWall();
  setPhase('ready');
  const d = S.device;
  $('#devName').textContent = d.name;
  $('#devSub').textContent = `${d.model || ''}${d.ios && d.ios !== '-' ? '，iOS ' + d.ios : ''}，读取助手运行中，关掉此页即退出`;
  S.t0 = performance.now();
  $('#metric').textContent = '正在读取最新照片…';
  renderTray(); updateCounts();
  loadPage(FIRST_PAGE);
}

function loadPage(limit) {
  if (S.loading || S.done) return;
  S.loading = true;
  const gen = S.gen;
  host.call('list', { cursor: S.cursor, limit }).then(r => {
    if (gen !== S.gen) return;
    S.cursor = r.cursor; S.done = !r.cursor; S.loading = false;
    if (S.items.length === 0 && r.items.length) {
      $('#metric').textContent = `列出最新 ${r.items.length} 项用时 ${((performance.now() - S.t0) / 1000).toFixed(1)} 秒，缩略图加载中…`;
    }
    append(r.items);
    afterLoad();
  }).catch(e => {
    if (gen !== S.gen) return;
    S.loading = false;
    if (e.code === 'device_lost') onDeviceLost();
    else if (e.code !== 'host_gone') toast('读取照片列表失败：' + e.message, true);
  });
}

function wantMore() {
  if (S.done || S.loading) return false;
  if (S.mode === 'today' && S.sawOlder) return false;
  const r = $('#sentinel').getBoundingClientRect();
  return r.top < innerHeight + 900;
}
function afterLoad() {
  updateCounts(); renderEndnote();
  if (wantMore()) loadPage(NEXT_PAGE);
}
new IntersectionObserver(es => { if (es.some(e => e.isIntersecting) && wantMore()) loadPage(NEXT_PAGE); },
  { rootMargin: '900px 0px' }).observe($('#sentinel'));

function append(items) {
  const td = today();
  for (const it of items) {
    if (S.byId.has(it.id)) continue;
    S.items.push(it); S.byId.set(it.id, it);
    if (dayKey(it.t) < td) S.sawOlder = true;
    if (shown(it)) addTile(it);
  }
}

function groupFor(key) {
  let g = S.groups.get(key);
  if (g) return g;
  const [label, sub] = dayLabel(key);
  const el = document.createElement('section');
  el.className = 'group'; el.dataset.day = key;
  el.innerHTML = `<div class="ghead"><h3>${label}</h3><span>${sub}</span><span class="gcount"></span>
    <button data-gsel="${key}">全选这一组</button></div><div class="grid"></div>`;
  // 按日期倒序插入
  const after = [...$('#groups').children].find(x => x.dataset.day < key);
  $('#groups').insertBefore(el, after || null);
  g = { el, grid: el.querySelector('.grid'), count: el.querySelector('.gcount'), btn: el.querySelector('[data-gsel]'), ids: [] };
  S.groups.set(key, g);
  return g;
}

function tileLabel(it) {
  if (it.kind === 'video') return '▶ ' + it.ext;
  return it.ext;
}
function addTile(it) {
  const g = groupFor(dayKey(it.t));
  g.ids.push(it.id);
  const b = document.createElement('button');
  b.className = 'tile'; b.dataset.id = it.id;
  b.dataset.label = it.kind === 'video' ? '视频' : it.ext;
  b.setAttribute('aria-pressed', S.sel.has(it.id));
  b.setAttribute('aria-label', `${it.name}，${hhmm(it.t)}`);
  b.innerHTML = `${it.live ? '<span class="lv">实况</span>' : ''}<span class="ck">${S.sel.has(it.id) ? '✓' : ''}</span>
    <span class="ty">${esc(tileLabel(it))}</span><span class="tm">${hhmm(it.t)}</span><span class="zm" data-zoom>放大</span>`;
  applyThumb(b, it.id);
  g.grid.appendChild(b);
  g.count.textContent = `${g.ids.length} 项`;
  tileObserver.observe(b);
}

function rebuildWall() {
  S.groups.clear(); S.visible.clear(); S.queue = [];
  $('#groups').innerHTML = '';
  for (const it of S.items) if (shown(it)) addTile(it);
  updateGroupButtons(); updateCounts(); renderEndnote();
  scrollTo({ top: 0 });
  if (wantMore()) loadPage(NEXT_PAGE);
}

function updateCounts() {
  const td = today();
  const nToday = S.items.filter(i => dayKey(i.t) === td).length;
  $('#cntToday').textContent = nToday + (S.sawOlder || S.done ? '' : '+');
  $('#cntAll').textContent = S.done ? S.items.length : `已载入 ${S.items.length}`;
}

function renderEndnote() {
  const el = $('#endnote');
  const n = shownOrder().length;
  if (S.mode === 'today' && (S.sawOlder || S.done)) {
    el.innerHTML = n === 0
      ? `今天还没有照片。<br><button class="ghost" data-act="all">看最近的照片</button>`
      : `今天的照片就这些。<br><button class="ghost" data-act="all">继续看更早的</button>`;
  } else if (S.mode === 'all' && S.done) {
    el.textContent = `已经到底，共 ${S.items.length} 项。`;
  } else {
    el.textContent = S.loading || !S.done ? '往下滚动加载更多…' : '';
  }
}
$('#endnote').addEventListener('click', e => { if (e.target.closest('[data-act="all"]')) setMode('all'); });

function setMode(m) {
  if (S.mode === m) return;
  S.mode = m;
  document.querySelectorAll('#modes button').forEach(b => b.setAttribute('aria-pressed', b.dataset.mode === m));
  rebuildWall();
}
$('#modes').addEventListener('click', e => { const b = e.target.closest('[data-mode]'); if (b) setMode(b.dataset.mode); });
$('#refresh').addEventListener('click', () => {
  host.call('refresh').then(() => enterReady()).catch(() => {});
});

/* ------------------------------------------------------------ thumbnails (只请求屏幕附近的) */
const tileObserver = new IntersectionObserver(entries => {
  for (const e of entries) {
    const id = e.target.dataset.id;
    if (e.isIntersecting) {
      S.visible.add(id);
      if (!S.thumbs.has(id) && !S.requested.has(id) && !S.meta.get(id)?.noThumb) S.queue.push(id);
    } else S.visible.delete(id);
  }
  pump();
}, { rootMargin: '600px 0px' });

function pump() {
  while (S.active < THUMB_CONCURRENCY && S.queue.length) {
    // 先处理最近进入视野的（用户正在看的地方）
    const id = S.queue.pop();
    if (!S.visible.has(id) || S.thumbs.has(id) || S.requested.has(id)) continue;
    S.requested.add(id); S.active++;
    const gen = S.gen;
    host.call('thumb', { id }).then(r => {
      if (gen !== S.gen) return;
      setThumb(id, r);
    }).catch(e => {
      if (gen !== S.gen) return;
      S.requested.delete(id);
      if (e.code === 'device_lost') onDeviceLost();
    }).finally(() => { if (gen === S.gen) { S.active--; pump(); } });
  }
}

function b64ToUrl(b64, type = 'image/jpeg') {
  const bin = atob(b64); const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return URL.createObjectURL(new Blob([arr], { type }));
}
function setThumb(id, r) {
  S.meta.set(id, r);
  if (r.thumb) S.thumbs.set(id, b64ToUrl(r.thumb));
  const el = document.querySelector(`.tile[data-id="${CSS.escape(id)}"]`);
  if (el) applyThumb(el, id);
  if (S.sel.has(id)) renderTray();
  checkFirstScreen();
}
function applyThumb(el, id) {
  const u = S.thumbs.get(id);
  if (u) { el.style.backgroundImage = `url("${u}")`; el.classList.add('has'); }
  else if (S.meta.get(id)?.noThumb) el.classList.add('nothumb');
}
function checkFirstScreen() {
  if (S.firstShown) return;
  const first = shownOrder().slice(0, 20);
  if (!first.length) return;
  if (first.every(id => S.thumbs.has(id) || S.meta.get(id)?.noThumb)) {
    S.firstShown = true;
    const cached = first.filter(id => S.meta.get(id)?.cached).length;
    $('#metric').textContent = `首屏 ${first.length} 张用时 ${((performance.now() - S.t0) / 1000).toFixed(1)} 秒` +
      (cached ? `（其中 ${cached} 张来自缓存）` : '');
  }
}

/* ------------------------------------------------------------ selection */
function toggle(id, shift) {
  const order = shownOrder();
  if (shift && S.last && order.includes(S.last)) {
    const a = order.indexOf(S.last), b = order.indexOf(id);
    const on = !S.sel.has(id);
    order.slice(Math.min(a, b), Math.max(a, b) + 1).forEach(x => on ? S.sel.add(x) : S.sel.delete(x));
    order.slice(Math.min(a, b), Math.max(a, b) + 1).forEach(refreshTile);
  } else {
    S.sel.has(id) ? S.sel.delete(id) : S.sel.add(id);
    refreshTile(id);
  }
  S.last = id;
  updateGroupButtons(); renderTray();
}
function refreshTile(id) {
  const el = document.querySelector(`.tile[data-id="${CSS.escape(id)}"]`);
  if (!el) return;
  const on = S.sel.has(id);
  el.setAttribute('aria-pressed', on);
  el.querySelector('.ck').textContent = on ? '✓' : '';
}
function updateGroupButtons() {
  for (const g of S.groups.values()) g.btn.textContent = g.ids.every(i => S.sel.has(i)) ? '取消这一组' : '全选这一组';
}

$('#groups').addEventListener('click', e => {
  if (S.exporting) return;
  const gs = e.target.closest('[data-gsel]');
  if (gs) {
    const g = S.groups.get(gs.dataset.gsel);
    const all = g.ids.every(i => S.sel.has(i));
    g.ids.forEach(i => all ? S.sel.delete(i) : S.sel.add(i));
    g.ids.forEach(refreshTile); updateGroupButtons(); renderTray();
    return;
  }
  const t = e.target.closest('.tile');
  if (!t) return;
  const id = t.dataset.id;
  if (e.target.closest('[data-zoom]')) { openPv(id); return; }
  const now = Date.now();
  if (S.lastTap.id === id && now - S.lastTap.t < 320) {   // 双击 = 放大（撤销第一次点击的选择）
    S.lastTap = {}; toggle(id, false); openPv(id); return;
  }
  S.lastTap = { id, t: now };
  toggle(id, e.shiftKey);
});

/* ------------------------------------------------------------ tray + export */
function selectedItems() { return [...S.sel].map(id => S.byId.get(id)).filter(Boolean); }
function exportDirLabel() { const d = new Date(); return `下载 › iPhone ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; }

function renderTray() {
  const tray = $('#tray');
  if (S.exporting) return;
  const items = selectedItems();
  const files = items.reduce((a, i) => a + i.fileCount, 0);
  const bytes = items.reduce((a, i) => a + i.size, 0);
  tray.innerHTML = `
    <div class="tcount"><strong>已选 ${items.length} 张</strong>
      <small>${items.length ? `${files} 个文件，约 ${mb(bytes)} MB` : '点照片选择，Shift 连选，双击放大'}</small></div>
    <div class="strip">${items.slice(0, 12).map(i => `<i style="${S.thumbs.has(i.id) ? `background-image:url('${S.thumbs.get(i.id)}')` : ''}"></i>`).join('')}</div>
    ${items.length ? '<button class="linkbtn" data-act="clear">清空</button>' : ''}
    <div class="spacer"></div>
    <span class="dest">导出到：${exportDirLabel()}</span>
    <button class="primary" data-act="export" ${items.length ? '' : 'disabled'}>导出${items.length ? ' ' + items.length + ' 张' : ''}</button>`;
}
$('#tray').addEventListener('click', e => {
  const a = e.target.closest('[data-act]');
  if (!a) return;
  if (a.dataset.act === 'clear') { const ids = [...S.sel]; S.sel.clear(); ids.forEach(refreshTile); updateGroupButtons(); renderTray(); }
  if (a.dataset.act === 'export') doExport();
});

let exportRid = null;
function onHostEvent(m) {
  if (m.event === 'progress' && S.exporting) {
    const pct = Math.round(m.done / m.total * 100);
    const t = $('#progText'), b = $('#progBar');
    if (t) t.textContent = m.file ? `正在从 iPhone 读取原文件 ${m.index}/${m.count}：${m.file}（${pct}%）` : '正在完成…';
    if (b) b.style.width = pct + '%';
  }
}
function doExport() {
  const items = selectedItems();
  if (!items.length) return;
  S.exporting = true;
  $('#tray').innerHTML = `<div class="prog"><small id="progText">准备中…</small><div class="bar"><i id="progBar"></i></div></div>`;
  host.call('export', { ids: items.map(i => i.id) }).then(r => {
    S.exporting = false;
    const ids = [...S.sel]; S.sel.clear(); ids.forEach(refreshTile); updateGroupButtons(); renderTray();
    const folder = r.dir.split('/').pop();
    const skipped = r.skipped ? `，${r.skipped} 个文件已存在所以跳过` : '';
    toast(`已导出 ${r.count} 张（写入 ${r.files.length} 个文件${skipped}）到“下载 / ${esc(folder)}”`, false,
      { label: '在访达中打开', fn: () => host.call('reveal', { path: r.dir }) });
  }).catch(e => {
    S.exporting = false; renderTray();
    if (e.code === 'device_lost') { toast('导出中断：iPhone 断开了连接', true); onDeviceLost(); }
    else toast('导出失败：' + e.message, true);
  });
}

let toastTimer = null;
function toast(html, isErr, action) {
  const t = $('#toast');
  t.className = 'toast' + (isErr ? ' err' : '');
  t.innerHTML = `<span>${html}</span>${action ? `<button>${action.label}</button>` : ''}`;
  if (action) t.querySelector('button').onclick = action.fn;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, isErr ? 8000 : 6000);
}

/* ------------------------------------------------------------ preview */
function openPv(id) { S.pvId = id; drawPv(); }
function closePv() { S.pvId = null; $('#pv').hidden = true; $('#pv').innerHTML = ''; }
function stepPv(k) {
  const order = shownOrder(); if (!order.length) return;
  const i = order.indexOf(S.pvId);
  S.pvId = order[(i + k + order.length) % order.length];
  drawPv();
}
function drawPv() {
  const id = S.pvId, it = S.byId.get(id);
  if (!it) return closePv();
  const meta = S.meta.get(id) || {};
  const on = S.sel.has(id);
  const low = S.thumbs.get(id) || '';
  const pv = $('#pv');
  const dims = meta.w && meta.h ? `${meta.w} × ${meta.h}` : '—';
  const taken = meta.taken ? meta.taken.replace(/^(\d{4}):(\d{2}):(\d{2})/, '$1-$2-$3') : `${dayKey(it.t)} ${hhmm(it.t)}`;
  const hint = it.kind === 'video' ? '视频这一版只显示第一帧，导出时是原始文件。'
    : (it.ext === 'HEIC' ? '大图是读取助手临时转成 JPEG 显示的，导出时仍是原始 HEIC。' : '导出时保持原始文件。');
  pv.innerHTML = `<div class="stage">
      <img id="pvImg" class="${S.previews.has(id) ? '' : 'low'}" src="${S.previews.get(id) || low}" alt="${esc(it.name)}">
      <button class="arrow l" data-pv="-1" aria-label="上一张">‹</button><button class="arrow r" data-pv="1" aria-label="下一张">›</button>
    </div>
    <aside><h4>${esc(it.name)}</h4>
      <dl><dt>拍摄</dt><dd>${esc(taken)}</dd><dt>格式</dt><dd>${esc(it.ext)}${it.live ? '（实况）' : ''}</dd>
      <dt>尺寸</dt><dd>${dims}</dd><dt>大小</dt><dd>${mb(it.size)} MB</dd>
      ${it.live ? `<dt>配对</dt><dd>${esc(it.liveName)}</dd>` : ''}</dl>
      <div class="hint">${hint}</div>
      <button class="${on ? 'ghost' : 'primary'}" data-pvsel>${on ? '取消选择' : '选中这张'}</button>
      <button class="ghost" data-pvclose>关闭</button>
      <div class="keys">← → 切换，空格选择，Esc 关闭</div></aside>`;
  pv.hidden = false;
  if (!S.previews.has(id)) {
    host.call('preview', { id }).then(r => {
      if (!r.data) return;
      const u = b64ToUrl(r.data);
      S.previews.set(id, u);
      if (S.previews.size > 40) { const [k, v] = S.previews.entries().next().value; URL.revokeObjectURL(v); S.previews.delete(k); }
      if (S.pvId === id) { const img = $('#pvImg'); img.src = u; img.classList.remove('low'); }
    }).catch(e => { if (e.code === 'device_lost') { closePv(); onDeviceLost(); } });
  }
}
$('#pv').addEventListener('click', e => {
  const a = e.target.closest('[data-pv]');
  if (a) { stepPv(+a.dataset.pv); return; }
  if (e.target.closest('[data-pvsel]')) { toggle(S.pvId, false); drawPv(); return; }
  if (e.target.closest('[data-pvclose]') || e.target.classList.contains('stage') || e.target === $('#pv')) closePv();
});
document.addEventListener('keydown', e => {
  if (!S.pvId) return;
  if (e.key === 'Escape') closePv();
  else if (e.key === 'ArrowRight') stepPv(1);
  else if (e.key === 'ArrowLeft') stepPv(-1);
  else if (e.key === ' ') { e.preventDefault(); toggle(S.pvId, false); drawPv(); }
});

new ResizeObserver(() => document.documentElement.style.setProperty('--toph', $('#top').offsetHeight + 'px')).observe($('#top'));
start();
