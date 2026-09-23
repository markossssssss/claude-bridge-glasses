<script def>
{
  "navigationBarTitleText": "Claude",
  "description": "管理用户电脑上多个 Claude Code 开发 agent：查看每个 agent 在做什么、切换、给某个 agent 下指令、批准或拒绝它的操作。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "text": { "type": "string", "description": "用户要对 agent 说的话或管理指令，原样传入，不要改写或总结" }
      }
    }
  },
  "disableScroll": true
}
</script>
<script setup>
// 由 build.sh 替换；源码里不放真实 token
const BASE = 'https://bridge.jushoop1977.com';
// 公开构建里为空：首次打开走配对，token 存在眼镜本地
const BUILTIN_TOKEN = '';
let TOKEN = '';
try { TOKEN = localStorage.getItem('bridge_token') || BUILTIN_TOKEN; } catch (e) { TOKEN = BUILTIN_TOKEN; }

// 远程日志：真机上看不到控制台，日志批量回传 relay（relay/data/glasses-device.log）
const logBuf = [];
function dlog(msg) {
  console.log('[bridge] ' + msg);
  logBuf.push({ ts: Date.now(), t: String(msg) });
  if (logBuf.length > 400) logBuf.splice(0, logBuf.length - 400);
}
function flushLogs() {
  if (!TOKEN || !logBuf.length) return;
  const lines = logBuf.splice(0, logBuf.length);
  wx.request({ url: BASE + '/api/glasses/log?token=' + TOKEN, method: 'POST', header: { 'content-type': 'application/json' },
    data: { lines: lines }, timeout: 15000, success: () => {}, fail: () => { logBuf.unshift.apply(logBuf, lines.slice(-200)); } });
}
// 仅测试构建为 true：浏览器预览没有语音识别，单击用预设句子代替
const DEV_TEXT = 'false';
const BUILD = 'f2e5d98';   // 构建来源提交，日志里能确认眼镜跑的是哪一版

const LISTEN_TIMEOUT_MS = 15000;
const BOARD_POLL_MS = 8000;
const SESSION_POLL_MS = 20000;
const BOARD_ROWS = 8;          // 管理台一屏 4 个 agent，每个两行
// 480x352 HUD，18px 字：每行约 24 个汉字，正文区约 11 行
const LINE_CHARS = 24;
const PAGE_LINES = 11;

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const sep = path.indexOf('?') >= 0 ? '&' : '?';
    const opts = {
      url: BASE + path + sep + 'token=' + TOKEN,
      method: method,
      header: { 'content-type': 'application/json' },
      timeout: 60000,
      success: (res) => {
        if (res && res.statusCode === 401) { try { localStorage.removeItem('bridge_token'); } catch (e) {} TOKEN = ''; }
        if (!res || res.statusCode !== 200) { reject(new Error('HTTP ' + (res && res.statusCode))); return; }
        let d = res.data;
        if (typeof d === 'string') { try { d = JSON.parse(d); } catch (e) { reject(new Error('bad json')); return; } }
        resolve(d);
      },
      fail: (err) => reject(new Error((err && (err.errMsg || err.message)) || 'network')),
    };
    if (method !== 'GET') opts.data = body || {};  // GET 带请求体会被直接拒绝
    wx.request(opts);
  });
}

// 按显示宽度分页：汉字算 1，ASCII 算 0.55；空行保留
function paginate(text) {
  const pages = []; let page = []; let used = 0;
  const push = () => { if (page.length) pages.push(page.join('\n')); page = []; used = 0; };
  for (const raw of String(text || '').split('\n')) {
    let line = raw;
    do {
      let w = 0, cut = 0;
      for (const ch of line) { const cw = ch.charCodeAt(0) < 128 ? 0.55 : 1; if (w + cw > LINE_CHARS) break; w += cw; cut += ch.length; }
      const piece = line.slice(0, cut || line.length); line = line.slice(cut || line.length);
      if (used >= PAGE_LINES) push();
      page.push(piece); used += 1;
    } while (line.length);
  }
  push();
  return pages.length ? pages : [''];
}

function clip(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
// 按显示宽度截断（汉字 1，ASCII 0.55），units = 一行能放的汉字数
function clipW(s, units) {
  s = String(s || ''); let w = 0, out = '';
  for (const ch of s) { const cw = ch.charCodeAt(0) < 128 ? 0.55 : 1; if (w + cw > units - 1) return out + '…'; w += cw; out += ch; }
  return out;
}
// Ink 的 <text> 不渲染换行：正文按行拆成数组逐行渲染
// 模板是单一结构：管理台和 agent 页只换数据不换元素（Ink 下条件块切换回来后内部列表不会重画）
function toLines(text) {
  return String(text || '').split('\n').map((t, i) => ({ id: 's' + i, cls: 'ln', bcls: 'bar', tcls: t.indexOf('你：') === 0 ? 'tx q' : 'tx', t: t || ' ' }));
}
function ago(ms) {
  if (!ms) return '';
  const m = Math.floor(ms / 60000);
  return m < 1 ? '刚刚' : m < 60 ? m + '分' : Math.floor(m / 60) + '时' + (m % 60 ? m % 60 + '分' : '');
}
// 需要人处理的排前面：待批 > 新回复 > 忙 > 空闲 > 离线
function attention(s) { return !s.online ? 4 : s.pending ? 0 : s.unread ? 1 : s.busy ? 2 : 3; }

export default {
  data: {
    view: 'board',
    // 管理台
    boardTop: 'Agent 管理台', boardHint: '', foot: '',
    // 会话页
    status: 'idle', label: '单击说话', heard: '', answer: '', hint: '', top: '单击说话', main: '', lines: [], session: '', others: '',
  },
  board: [], sel: 0, now: 0, sessionTicks: 0,
  recognition: null, listenTimer: null, pollTimer: null, flushTimer: null, hookTimer: null, aborting: false,
  pendingChat: '', pendingIndex: 0,
  lastSwipe: 0, pager: null, epoch: 0, devTurn: 0,
  target: '',        // 管理台上说话时对哪个 agent

  // ---------------------------------------------------------------- 会话页状态
  set(status, patch) {
    const labels = { idle: '单击说话', listening: '在听…', thinking: '处理中…', confirm: '说"允许"或"拒绝"', error: '出错了，单击重试', reading: '' };
    dlog(status + ' ' + JSON.stringify(patch || {}));
    const next = Object.assign({}, this.data, { status: status, label: labels[status] }, patch || {});
    const base = (next.session ? '[' + next.session + '] ' : '') + next.label;
    next.top = next.heard && status !== 'idle' ? base + ' · ' + next.heard : base;
    next.main = next.hint ? (next.answer ? next.answer + '\n' + next.hint : next.hint) : next.answer;
    if (this.data.view === 'board') return;  // 管理台由 renderBoard 负责画
    this.setData(Object.assign({ status: status, label: labels[status], top: next.top, main: next.main, lines: toLines(next.main), foot: next.others || this.data.others }, patch || {}));
  },

  speak(text) {
    if (!text) return;
    try { speechSynthesis.speak(new SpeechSynthesisUtterance(text), 'enqueue'); }
    catch (e) { try { wx.speech.playTTS(text); } catch (e2) { dlog('tts unavailable'); } }
  },

  // ---------------------------------------------------------------- 生命周期
  onLoad(options) {
    const q = options && (typeof options.query === 'string' ? options.query : options.text);
    this.flushTimer = setInterval(flushLogs, 2000);
    dlog('load build=' + BUILD + ' token=' + (TOKEN ? 'yes' : 'no') + ' SR=' + typeof SpeechRecognition + ' query=' + JSON.stringify(q || ''));
    if (!TOKEN) { this.startPairing(); return; }
    this.startApp(q);
  },

  startApp(q) {
    this.showBoard();
    if (!this.pollTimer) this.pollTimer = setInterval(() => this.tick(), BOARD_POLL_MS);
    if (q) this.ask(q);
  },

  // 首次配对：显示 6 位码，在 Hub 上批准后拿到这副眼镜的专属 token
  async startPairing() {
    this.data.view = 'pair';
    try {
      const r = await new Promise((resolve, reject) => wx.request({ url: BASE + '/api/glasses/pair/start', method: 'POST',
        header: { 'content-type': 'application/json' }, data: { device: 'glasses' }, timeout: 15000,
        success: (res) => res.statusCode === 200 ? resolve(typeof res.data === 'string' ? JSON.parse(res.data) : res.data) : reject(new Error('HTTP ' + res.statusCode)),
        fail: (e) => reject(new Error((e && e.errMsg) || 'network')) }));
      this.setData({ top: '配对这副眼镜', lines: toLines('配对码\n\n' + r.code + '\n\n在手机 Hub 上点"批准"\n（10 分钟内有效）'), foot: '等待批准…' });
      this.speak('配对码 ' + r.code.split('').join(' '));
      dlog('pair code ' + r.code + ' id ' + r.pair_id);
      const started = Date.now();
      const poll = async () => {
        if (this.data.view !== 'pair') return;
        if (Date.now() - started > 590000) { this.startPairing(); return; }
        const p = await new Promise((resolve) => wx.request({ url: BASE + '/api/glasses/pair/poll?pair_id=' + r.pair_id, method: 'GET', timeout: 15000,
          success: (res) => { try { resolve(res.statusCode === 200 ? (typeof res.data === 'string' ? JSON.parse(res.data) : res.data) : { status: 'expired' }); } catch (e) { resolve({ status: 'pending' }); } },
          fail: () => resolve({ status: 'pending' }) }));
        if (p.status === 'approved' && p.token) {
          TOKEN = p.token; try { localStorage.setItem('bridge_token', TOKEN); } catch (e) {}
          dlog('paired'); this.speak('配对成功'); this.startApp(''); return;
        }
        if (p.status === 'expired') { this.startPairing(); return; }
        setTimeout(poll, 3000);
      };
      setTimeout(poll, 3000);
    } catch (e) {
      this.setData({ top: '配对这副眼镜', lines: toLines('连不上 relay：' + (e.message || e) + '\n单击重试'), foot: '' });
    }
  },

  onUnload() { if (this.pollTimer) clearInterval(this.pollTimer); if (this.flushTimer) clearInterval(this.flushTimer); flushLogs(); },

  tick() {
    if (this.data.view === 'board') { if (this.data.status !== 'listening' && this.data.status !== 'thinking') this.refreshBoard(); return; }
    this.sessionTicks += 1;
    if (this.sessionTicks * BOARD_POLL_MS >= SESSION_POLL_MS && (this.data.status === 'idle' || this.data.status === 'confirm')) { this.sessionTicks = 0; this.refreshStatus(); }
  },

  // ---------------------------------------------------------------- 管理台
  showBoard() {
    this.epoch++; this.pager = null; this.pendingChat = '';
    this.data.view = 'board'; this.setData({ status: 'idle' });
    dlog('board-view');
    this.refreshBoard();
  },

  async refreshBoard() {
    try {
      const st = await request('GET', '/api/glasses/status');
      const keep = this.board[this.sel] && this.board[this.sel].name;
      this.now = st.now || Date.now();
      // 先按需不需要处理，同一档内最近有动静的排前面
      this.board = st.sessions.slice().sort((a, b) => attention(a) - attention(b) || (b.lastActivity || 0) - (a.lastActivity || 0) || a.index - b.index);
      const i = this.board.findIndex((s) => s.name === keep);
      this.sel = i >= 0 ? i : 0;
      this.renderBoard();
    } catch (e) { this.setData({ foot: '连不上 relay：' + (e.message || e) }); dlog('board failed ' + (e.message || e)); }
  },

  renderBoard() {
    const b = this.board, n = b.length;
    const busy = b.filter((s) => s.busy).length, pend = b.filter((s) => s.pending).length, unread = b.filter((s) => s.unread).length;
    const start = Math.max(0, Math.min(this.sel - 2, n - BOARD_ROWS));
    const rows = b.slice(start, start + BOARD_ROWS).map((s, k) => {
      const i = start + k, selected = i === this.sel;
      // 分支对所有 workbench 会话都一样，没有区分度，不显示；cockpit 里没接管的标出来
      const state = !s.online ? '离线' : s.adoptable ? (s.pending ? '待确认·未接管' : s.busy ? '忙·未接管' : '未接管')
        : s.pending ? '待批' : s.unread ? '新回复' + s.unread : s.busy ? '忙' + ago(this.now - s.busySince) : '空闲';
      const sub = s.adoptable ? (s.task ? '未接管 · ' + s.task : '未接管，单击进入会自动接管')
        : s.pending ? '待批：' + (s.permission || s.last || '等你确认')
        : s.unread ? '回复：' + s.last
        : s.busy ? '在做：' + (s.task || '…')
        : s.last ? '最近：' + s.last : s.task ? '最近：' + s.task : '还没有对话';
      const lvl = selected ? ' sel' : attention(s) <= 1 ? ' hot' : '';
      return { title: clipW(s.label + ' · ' + state, 23), sub: clipW(sub, 26), lvl: lvl, selected: selected, id: s.name };
    });
    const lines = [];
    rows.forEach((r, k) => {
      lines.push({ id: 'bt' + k, cls: 'ln row' + r.lvl, bcls: r.selected ? 'bar on' : 'bar', tcls: 'tx bt', t: r.title });
      // 只有选中的展开详情，一屏能多放几个 agent
      if (r.selected) lines.push({ id: 'bs' + k, cls: 'ln row gap' + r.lvl, bcls: 'bar', tcls: 'tx bs', t: r.sub });  // 竖条只画在标题行
    });
    if (!rows.length) lines.push({ id: 'b-empty', cls: 'ln', bcls: 'bar', tcls: 'tx', t: '还没有 agent，说"新建会话叫…"' });
    const top = 'Agent 管理台 · ' + n + '个' + (busy ? ' · 忙' + busy : '') + (pend ? ' · 待批' + pend : '') + (unread ? ' · 新回复' + unread : '');
    const foot = n ? (this.sel + 1) + '/' + n + ' 滑动选择 · 单击进入 · 说话=对选中的' : '';
    this.setData({ top: top, lines: lines, foot: this.data.boardHint || foot, boardTop: top });
    this.data.boardHint = '';
    dlog('board ' + JSON.stringify({ sel: this.sel, rows: rows.map((r) => r.title) }));
  },

  moveSel(dir) {
    if (!this.board.length) return;
    this.sel = (this.sel + dir + this.board.length) % this.board.length;
    this.renderBoard();
    const s = this.board[this.sel];
    this.speak(s.label + (s.pending ? '，待批' : s.unread ? '，有新回复' : s.busy ? '，在忙' : ''));
  },

  async enterSession(name) {
    const my = ++this.epoch; this.pager = null; this.pendingChat = '';
    try {
      const r = await request('POST', '/api/glasses/select', { session: name });
      if (my !== this.epoch) return;
      if (r.type !== 'selected') { this.setData({ foot: r.text || '进不去' }); return; }
      this.data.view = 'session';
      this.set('idle', { session: r.label + ' ' + r.index + '/' + r.total, heard: '', answer: '', hint: '' });
      if (r.unread || r.pending) this.fetchUnread(); else this.showLastTurn();
      this.refreshStatus();
    } catch (e) { this.setData({ foot: String(e.message || e) }); }
  },

  // ---------------------------------------------------------------- 会话页
  async refreshStatus() {
    try {
      const st = await request('GET', '/api/glasses/status');
      const cur = st.sessions.find((x) => x.name === st.current);
      const others = st.sessions.filter((x) => x.name !== st.current && (x.unread || x.pending))
        .map((x) => x.label + (x.unread ? ' 新回复' + x.unread : '') + (x.pending ? ' 待批' + x.pending : '')).join(' · ');
      const o = (others ? others + ' · ' : '') + '向前滑回管理台 · 向后滑看历史';
      this.setData(this.data.view === 'session' ? { others: o, foot: o } : { others: o });
      if (cur && this.data.view === 'session') this.set(this.data.status, { session: cur.label + ' ' + cur.index + '/' + st.sessions.length });
    } catch (e) { dlog('status failed ' + (e.message || e)); }
  },

  async switchSession(dir) {
    this.epoch++; this.pendingChat = ''; this.pager = null;
    try {
      const r = await request('POST', '/api/glasses/select', { dir: dir });
      if (r.type !== 'selected') { this.set('error', { hint: r.text || '没有可切换的会话' }); return; }
      this.speak(r.label + (r.unread ? '，有' + r.unread + '条新回复' : '') + (r.pending ? '，有待批请求' : ''));
      this.set('idle', { session: r.label + ' ' + r.index + '/' + r.total, heard: '', answer: '', hint: '' });
      if (r.unread || r.pending) this.fetchUnread(); else this.showLastTurn();
      this.refreshStatus();
    } catch (e) { this.set('error', { hint: String(e.message || e) }); }
  },

  async fetchUnread() {
    const my = this.epoch;
    try {
      const r = await request('GET', '/api/glasses/unread');
      if (my !== this.epoch || r.type === 'none') return;
      this.handle(r, my);
    } catch (e) { dlog('unread failed'); }
  },

  async showLastTurn() {
    const my = this.epoch;
    try {
      const r = await request('GET', '/api/glasses/history?limit=1');
      if (my !== this.epoch || !r.items || !r.items.length) return;
      // 进入 agent 时只看一眼最新进展：显示第一屏，不进入分页；完整内容向后滑进历史看
      const pages = paginate(this.turnText(r.items[r.items.length - 1]));
      this.pager = null;
      this.set('idle', { answer: pages[0] + (pages.length > 1 ? '\n…（向后滑看完整历史）' : '') });
    } catch (e) {}
  },

  agentFoot() { return this.data.others || '向前滑回管理台 · 向后滑看历史'; },

  turnText(t) { return [t.q ? '你：' + t.q : '', t.a ? 'Claude：' + t.a : ''].filter(Boolean).join('\n\n'); },

  // 一页放得下就直接显示，放不下进入分页阅读
  showText(text, status) {
    const pages = paginate(text);
    if (pages.length <= 1) { this.pager = null; this.set(status || 'idle', { answer: text }); return; }
    this.pager = { pages: pages, labels: pages.map((_, i) => '第' + (i + 1) + '/' + pages.length + '页'), idx: 0, after: status || 'idle' };
    this.showPage(0);
  },

  async openHistory() {
    const my = this.epoch;
    this.set('thinking', { hint: '读取历史…' });
    try {
      const r = await request('GET', '/api/glasses/history?limit=20');
      if (my === this.epoch) this.enterHistory(r.items);
    } catch (e) { if (my === this.epoch) this.set('error', { hint: String(e.message || e) }); }
  },

  enterHistory(items) {
    if (!items || !items.length) { this.set('idle', { answer: '还没有对话记录' }); return; }
    const pages = [], labels = [];
    for (let k = items.length - 1; k >= 0; k--) {
      const ps = paginate(this.turnText(items[k]));
      ps.forEach((pg, j) => { pages.push(pg); labels.push('历史 ' + (items.length - k) + '/' + items.length + (ps.length > 1 ? ' · ' + (j + 1) + '/' + ps.length : '')); });
    }
    this.pager = { pages: pages, labels: labels, idx: 0, after: 'idle' };
    this.showPage(0);
  },

  showPage(i) {
    const p = this.pager; if (!p) return;
    p.idx = Math.max(0, Math.min(p.pages.length - 1, i));
    this.set('reading', { label: p.labels[p.idx], heard: '', answer: p.pages[p.idx], hint: '' });
    this.setData({ foot: (p.idx < p.pages.length - 1 ? '向后滑下一页 · ' : '已到最后 · ') + (p.idx > 0 ? '向前滑上一页' : '向前滑退出阅读') });
  },

  exitPager() {
    const p = this.pager; this.pager = null;
    this.set(p && p.after === 'confirm' ? 'confirm' : 'idle', { answer: p ? p.pages[0] : '', hint: '' });
    this.setData({ foot: this.agentFoot() });
  },

  // ---------------------------------------------------------------- 输入
  onVoiceWakeup(event) {
    // 接管 AI 键 / 唤醒词：由本应用来听
    event.preventDefault();
    this.listen();
  },

  // 真机实测（2026-09-23 日志统计）：
  //   单击 = GlobalHook → Enter（间隔 147–540ms，中位 494）
  //   滑动 = GlobalHook → ArrowRight/Left → ArrowDown/Up（首个方向键 9–345ms）
  //   双击 = GlobalHook ×2 → Backspace
  // 所以 GlobalHook 只当"触控板被碰到"，不据此做动作；动作只看 Enter / 方向键 / Backspace。
  onKeyDown(event) {
    dlog('key down ' + event.code + ' ' + (event.key || ''));
    const dir = this.swipeDir(event);
    if (!dir) return;
    event.preventDefault();
    this.cancelHook();
    const now = Date.now();
    if (this.lastSwipe && now - this.lastSwipe < 250) return;  // 一次滑动会连发两个方向键
    this.lastSwipe = now;
    if (this.data.status === 'listening') this.abortListen();  // 听的时候滑动 = 放弃这次说话
    if (this.data.view === 'board') { this.moveSel(dir); return; }
    // 双击是系统级"退出应用"，不会发给页面，所以返回靠向前滑：
    //   阅读中：向后滑下一页，向前滑上一页，第一页再向前滑退出阅读
    //   agent 页：向前滑回管理台，向后滑看这个 agent 的历史
    if (this.pager) {
      if (dir > 0) this.showPage(this.pager.idx + 1);
      else if (this.pager.idx > 0) this.showPage(this.pager.idx - 1);
      else this.exitPager();
      return;
    }
    if (dir < 0) { this.showBoard(); return; }
    this.openHistory();
  },

  swipeDir(event) {
    const c = event.code || event.key || '';
    if (c === 'ArrowDown' || c === 'ArrowRight' || c === 'PageDown') return 1;
    if (c === 'ArrowUp' || c === 'ArrowLeft' || c === 'PageUp') return -1;
    return 0;
  },

  onKeyUp(event) {
    dlog('key up ' + event.code + ' ' + (event.key || ''));
    if (this.swipeDir(event)) { event.preventDefault(); return; }
    // GlobalHook = 触控板被碰了一下，单击和滑动之前都会来，本身不代表动作。
    // 等 800ms：期间来了 Enter/方向键就交给它们；都没来才兜底当单击（有的固件只发它）。
    if (event.code === 'GlobalHook') {
      this.cancelHook();
      this.hookTimer = setTimeout(() => { this.hookTimer = null; dlog('hook fallback tap'); this.tap(); }, 800);
      return;
    }
    // 返回键（有的宿主双击发 Backspace）：管理台上交给系统（退出应用），其他情况按双击处理
    if (event.code === 'Backspace') {
      if (this.data.view === 'board' && this.data.status !== 'listening') return;
      event.preventDefault(); this.cancelHook(); this.doubleTap(); return;
    }
    if (event.code !== 'Enter') return;
    this.cancelHook();
    this.tap();  // 单击：语音识别就在这个事件里同步启动（必须在用户交互当下）
  },

  // 双击 = 返回：在听 → 停止；阅读中 → 退出阅读；agent 页 → 回管理台；管理台 → 不动
  doubleTap() {
    dlog('double tap');
    if (this.data.status === 'listening') { this.abortListen(); return; }
    if (this.pager) { this.exitPager(); return; }
    if (this.data.view === 'session') { this.showBoard(); return; }
  },

  cancelHook() { if (this.hookTimer) { clearTimeout(this.hookTimer); this.hookTimer = null; } },

  tap() {
    if (this.data.view === 'pair') { this.startPairing(); return; }
    if (this.data.view === 'board') {
      if (this.data.status === 'listening') { this.stopListening(); return; }
      const s = this.board[this.sel];
      if (s) this.enterSession(s.name); else this.listen();
      return;
    }
    if (this.pager) { this.pager = null; this.listen(); return; }
    if (this.data.status === 'thinking') { this.set('thinking', { hint: '还在处理，稍等' }); return; }
    if (this.data.status === 'listening') { this.stopListening(); return; }
    this.listen();
  },

  abortListen() {
    this.aborting = true;
    const r = this.recognition;
    this.clearListen();
    if (r) { try { r.abort(); } catch (e) {} }
    this.set(this.pendingChat ? 'confirm' : 'idle', { hint: '' });
  },

  listen() {
    // 管理台上说的话默认对选中的 agent；管理命令由 relay 识别
    this.target = this.data.view === 'board' && this.board[this.sel] ? this.board[this.sel].name : '';
    if (DEV_TEXT === 'true') {
      this.devTurn = (this.devTurn || 0) + 1;
      const script = ['一句话告诉我3加5等于几', '有哪些会话', '只读，不要修改任何东西：列出 /home/details-admin/JUSHOOP/workbench 根目录下所有文件和目录名，每个一行，全部放进 detail', '看看历史'];
      this.ask(this.data.status === 'confirm' ? '允许' : script[Math.min(this.devTurn - 1, script.length - 1)]);
      return;
    }
    if (typeof SpeechRecognition === 'undefined') { this.afterListen('这台设备没有语音识别'); return; }
    // 每次只识别一段，不自动续听（真机上 onend 后立刻重启的生命周期尚未被官方确认）
    const r = new SpeechRecognition();
    r.lang = 'zh-CN';
    r.interimResults = true;
    r.continuous = false;
    let finalText = '';
    let heard = '';
    const t0 = Date.now(); this.aborting = false;
    const ev = (name) => () => dlog('sr ' + name + ' +' + (Date.now() - t0) + 'ms');
    r.onstart = ev('start'); r.onaudiostart = ev('audiostart'); r.onsoundstart = ev('soundstart');
    r.onspeechstart = ev('speechstart'); r.onspeechend = ev('speechend'); r.onaudioend = ev('audioend');
    r.onnomatch = ev('nomatch');
    r.onresult = (ev) => {
      const res = ev.results[ev.resultIndex !== undefined ? ev.resultIndex : 0];
      const t = res && res[0] ? res[0].transcript : '';
      if (res && res.isFinal) finalText += t;
      heard = finalText || t;
      dlog('sr result +' + (Date.now() - t0) + 'ms final=' + !!(res && res.isFinal) + ' ' + JSON.stringify(t));
      if (this.data.view === 'board') this.setData({ foot: '在听… ' + heard });
      else this.setData({ heard: heard, top: '在听… · ' + heard });
    };
    r.onerror = (e) => {
      dlog('sr error +' + (Date.now() - t0) + 'ms ' + (e && e.error) + ' ' + (e && e.message));
      if (this.aborting) return;
      this.clearListen(); this.afterListen('识别失败：' + (e && e.error) + (e && e.message ? ' ' + e.message : ''));
    };
    r.onend = () => {
      const text = (finalText || heard || '').trim();
      dlog('sr end +' + (Date.now() - t0) + 'ms text=' + JSON.stringify(text) + (this.aborting ? ' (aborted)' : ''));
      if (this.aborting) { this.aborting = false; return; }
      this.clearListen();
      if (text) this.ask(text); else this.afterListen('没听清（' + (Date.now() - t0) + 'ms）');
    };
    this.recognition = r;
    if (this.data.view === 'board') { this.setData({ status: 'listening', foot: '在听…（说命令，或对选中的 agent 说）' }); dlog('listening board'); }
    else this.set('listening', { heard: '', hint: '' });
    this.listenTimer = setTimeout(() => {
      this.stopListening();
      // 宿主出错时 onerror/onend 可能都不来：再等 3 秒仍在听就强制复位
      setTimeout(() => { if (this.data.status === 'listening') { this.recognition = null; this.afterListen('识别没有响应，单击重试'); } }, 3000);
    }, LISTEN_TIMEOUT_MS);
    try { r.start(); dlog('sr start() called'); } catch (e) { dlog('sr start() threw ' + (e && (e.name + ' ' + e.message))); this.clearListen(); this.afterListen('无法开始识别：' + (e && e.name)); }
  },

  afterListen(msg) {
    if (this.data.view === 'board') { this.setData({ status: 'idle' }); this.data.boardHint = msg; this.renderBoard(); return; }
    this.set(this.pendingChat ? 'confirm' : 'idle', { hint: msg });
  },

  stopListening() { if (this.recognition) { try { this.recognition.stop(); } catch (e) {} } },

  clearListen() {
    if (this.listenTimer) { clearTimeout(this.listenTimer); this.listenTimer = null; }
    this.recognition = null;
  },

  // ---------------------------------------------------------------- 与 relay 交互
  async ask(text) {
    this.pager = null;
    const fromBoard = this.data.view === 'board';
    const body = { text: text };
    if (fromBoard && this.target) body.session = this.target;
    // 从管理台发出：进入会话页看结果（管理命令的回复会自行回管理台）
    if (fromBoard) this.data.view = 'session';
    const my = ++this.epoch;
    this.set('thinking', { heard: text, hint: '', answer: '' });
    try { this.handle(await request('POST', '/api/glasses/ask', body), my); }
    catch (e) { if (my === this.epoch) this.set('error', { hint: String(e.message || e) }); }
    if (fromBoard && this.data.view === 'session') this.refreshStatus();
  },

  async poll(chatId, after, my) {
    try { this.handle(await request('GET', '/api/glasses/wait?chat_id=' + chatId + '&after=' + after), my); }
    catch (e) { if (my === this.epoch) this.set('error', { hint: String(e.message || e) }); }
  },

  handle(res, my) {
    if (my !== undefined && my !== this.epoch) return;  // 已切走：这条留作原会话的未读
    if (!res) { this.set('error', { hint: '空响应' }); return; }
    if (res.type === 'reply') {
      const text = res.display ? res.text + '（已放到 pad）' : res.text;
      this.speak(text);  // 只朗读简短的 text；屏幕显示 text + detail
      if (res.interim) { this.set('thinking', { answer: text }); this.poll(res.chat_id, res.index + 1, this.epoch); return; }
      this.pendingChat = '';
      this.showText(res.detail ? text + '\n\n' + res.detail : text);
      return;
    }
    if (res.type === 'permission') {
      this.pendingChat = res.chat_id; this.pendingIndex = res.index;
      this.set('confirm', { answer: '要执行：' + res.description + (res.tool_name ? '（' + res.tool_name + '）' : '') });
      this.speak('Claude 想要' + res.description + '，说允许或拒绝');
      return;
    }
    if (res.type === 'working') { this.poll(res.chat_id, res.index, this.epoch); return; }
    if (res.type === 'relay') {
      this.speak(res.text);
      if (res.handled === 'verdict' && this.pendingChat) {
        const c = this.pendingChat; this.pendingChat = '';
        this.set('thinking', { answer: res.text });
        this.poll(c, this.pendingIndex, this.epoch);
        return;
      }
      if (res.handled === 'history') { this.enterHistory(res.items); return; }
      if (res.handled === 'back') { this.showBoard(); return; }
      // 列表/关闭/新消息这类全局命令：回管理台看全局
      if (['list', 'close', 'unread'].indexOf(res.handled) >= 0) { this.data.boardHint = res.text; this.showBoard(); return; }
      if (['switch', 'open', 'new', 'fork', 'rename'].indexOf(res.handled) >= 0) { this.epoch++; this.pendingChat = ''; this.pager = null; this.refreshStatus(); }
      this.set(res.handled === 'error' ? 'error' : 'idle', { answer: res.text });
      if (res.handled === 'switch' || res.handled === 'open') this.fetchUnread();
      return;
    }
    this.set('error', { hint: res.text || ('未知响应 ' + res.type) });
  },
};
</script>
<page>
  <view class="page">
    <text class="top">{{top}}</text>
    <view class="main">
      <view ink:for="{{lines}}" ink:key="id" class="{{item.cls}}">
        <text class="{{item.bcls}}">▌</text>
        <text class="{{item.tcls}}">{{item.t}}</text>
      </view>
    </view>
    <text class="rule">────────────────────────────────────────────────────────────</text>
    <text class="foot">{{foot}}</text>
  </view>
</page>
<style>
.page { width: 100%; height: 100%; padding: 12px 14px 10px 8px; background: #000000; display: flex; flex-direction: column; }
.top { color: #00ff00; opacity: 0.55; font-size: 16px; margin-bottom: 8px; padding-left: 14px; }
.main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.ln { display: flex; flex-direction: row; }
/* 竖条：每行都有，只有选中行可见，保证文字对齐 */
.bar { width: 14px; color: #00ff00; font-size: 18px; opacity: 0; }
.bar.on { opacity: 1; }
.tx { flex: 1; color: #00ff00; font-size: 18px; line-height: 1.33; }
.tx.q { opacity: 0.55; font-size: 16px; }
/* 管理台：未选中调暗、选中全亮；每个 agent 两行，组间留白 */
.row { opacity: 0.72; }   /* 单色屏上内容要比页头亮 */
.row.hot { opacity: 0.85; }
.row.sel { opacity: 1; }
.row.gap { margin-bottom: 14px; }
.tx.bt { font-size: 20px; font-weight: bold; line-height: 1.7; }  /* 行距放大用掉底部空白，仍 8 行 */
.tx.bs { font-size: 17px; opacity: 0.85; line-height: 1.5; }
.rule { color: #00ff00; opacity: 0.3; font-size: 12px; padding-left: 14px; overflow: hidden; }
.foot { color: #00ff00; opacity: 0.55; font-size: 14px; font-weight: bold; padding-left: 14px; }  /* 细笔画强光下先糊 */
</style>
