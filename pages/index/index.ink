<script def>
{
  "navigationBarTitleText": "Claude",
  "description": "管家：替用户盯着电脑上多个 Claude Code 开发 agent，汇报进度和阶段、转达指令、提醒需要用户决策或批准的事。",
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
const BUILD = '0925-1439';   // 构建来源提交，日志里能确认眼镜跑的是哪一版

const LISTEN_TIMEOUT_MS = 15000;
const STATUS_POLL_MS = 8000;   // 顶部状态行的刷新间隔
const NOTICE_POLL_MS = 4000;   // 管家主动汇报的轮询间隔（眼镜端只能拉，不能被推）
const CONCIERGE = 'concierge';
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

// 只有一个对话页：顶部一行全局状态，中间是对话，底栏是提示。
// 默认对象是管家；说"接通X"之后话直接发给 X（电脑上的会话也行），说"回来"回到管家。
// 手势只有三个：单击说话；向后滑往回翻（历史/长回复）；向前滑往前翻，翻到头回到最新。双击是系统的退出。
export default {
  data: { view: 'chat', status: 'idle', heard: '', answer: '', hint: '', top: '管家', lines: [], foot: '' },
  focus: { name: CONCIERGE, label: '管家' },
  overview: '', footNote: '',
  recognition: null, listenTimer: null, statusTimer: null, noticeTimer: null, flushTimer: null, hookTimer: null, aborting: false,
  pendingChat: '', pendingIndex: 0, lastSwipe: 0, pager: null, epoch: 0, devTurn: 0, noticeAfter: -1,

  // ---------------------------------------------------------------- 画面
  topLine() {
    const who = this.focus.name === CONCIERGE ? '管家' : '接通：' + this.focus.label;
    return clipW(who + (this.overview ? ' · ' + this.overview : ''), 26);
  },
  footLine(status) {
    if (this.footNote) return this.footNote;
    const f = { listening: '在听… 单击结束 · 滑动放弃', thinking: '处理中…', confirm: '说"允许"或"拒绝"', error: '单击重试' }[status];
    if (f) return f;
    return this.focus.name === CONCIERGE ? '单击说话 · 向后滑看历史' : '单击说话 · 说"回来"回到管家';
  },
  set(status, patch) {
    dlog(status + ' [' + this.topLine() + '] ' + JSON.stringify(patch || {}));
    const d = Object.assign({}, this.data, patch || {});
    let main = d.answer || '';
    if (status === 'listening') main = '在听…' + (d.heard ? '\n' + d.heard : '');
    else if (status === 'thinking' && d.heard && !d.answer) main = '你：' + d.heard + '\n\n处理中…';
    if (d.hint) main = main ? main + '\n' + d.hint : d.hint;
    this.setData(Object.assign({}, patch || {}, { status: status, top: this.topLine(), lines: toLines(main), foot: this.footLine(status) }));
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
  async startApp(q) {
    this.data.view = 'chat';
    if (!this.statusTimer) this.statusTimer = setInterval(() => this.refreshOverview(), STATUS_POLL_MS);
    if (!this.noticeTimer) { this.noticeTimer = setInterval(() => this.pollNotices(), NOTICE_POLL_MS); this.pollNotices(); }
    await this.selectFocus(CONCIERGE, '管家');
    const real = this.launchIntent(q);
    if (real) this.ask(real);
  },
  onUnload() { if (this.noticeTimer) clearInterval(this.noticeTimer); if (this.statusTimer) clearInterval(this.statusTimer); if (this.flushTimer) clearInterval(this.flushTimer); flushLogs(); },

  // ---------------------------------------------------------------- 对象与全局状态
  async selectFocus(name, label) {
    const my = ++this.epoch; this.pager = null; this.pendingChat = '';
    let r = null;
    try { r = await request('POST', '/api/glasses/select', { session: name }); } catch (e) {}
    if (my !== this.epoch) return;
    this.setFocus(name, (r && r.label) || label);
    this.set('idle', { heard: '', answer: '', hint: '' });
    this.refreshOverview();
    if (r && (r.unread || r.pending)) this.fetchUnread(); else this.showLastTurn();
  },
  setFocus(name, label) {
    if (this.focus.name === name && (!label || this.focus.label === label)) return;
    this.focus = { name: name, label: label || (name === CONCIERGE ? '管家' : name) };
    dlog('focus ' + name + ' ' + this.focus.label);
  },
  async refreshOverview() {
    try {
      const st = await request('GET', '/api/glasses/status');
      const others = st.sessions.filter((s) => !s.concierge);
      // 等你 = 有待批的确认，或处在真正任务阶段里标了"在等你"；问答类（杂项/已完成）不算
      const wait = others.filter((s) => s.pending || (s.waiting && s.stage && s.stage !== '杂项' && s.stage !== '已完成'));
      const busy = others.filter((s) => s.busy).length;
      this.overview = others.length + '个' + (wait.length ? ' 等你' + wait.length : '') + (busy ? ' 忙' + busy : '') + (wait.length ? ' · ' + wait.map((s) => s.label).join('、') : '');
      if (st.current) this.setFocus(st.current, st.currentLabel);   // 以 relay 为准：话发到哪，顶部就写哪
      this.setData({ top: this.topLine() });
    } catch (e) { dlog('status failed ' + (e.message || e)); }
  },

  // 管家的主动汇报：朗读短句；在管家对话里且空闲就上屏，否则放底栏，下次操作时清掉
  async pollNotices() {
    try {
      const r = await request('GET', '/api/glasses/notices?after=' + this.noticeAfter);
      this.noticeAfter = r.latest;
      (r.notices || []).forEach((n) => this.onNotice(n));
    } catch (e) {}
  },
  onNotice(n) {
    dlog('notice ' + n.id + ' ' + n.text);
    this.speak(n.text);
    if (this.focus.name === CONCIERGE && !this.pager && (this.data.status === 'idle' || this.data.status === 'error')) {
      this.showText('【汇报】' + n.text + (n.detail ? '\n\n' + n.detail : ''));
      return;
    }
    this.footNote = '【汇报】' + n.text;
    this.setData({ foot: this.footNote });
  },

  // 系统助手唤起应用时，会把整句唤起语（"打开claude控制台"）当参数塞进来。
  // 那不是你对某个会话说的话，原样发出去就成了第一条指令，会发给当时选中的会话。
  // 判断方式：把"打开/启动…"和应用名剥掉，如果什么都不剩，这句话就只是唤起语，丢掉；
  // 还剩东西说明你是带着话来的（"打开claude控制台 沙盒在做什么"），原句原样送，让 relay 自己解析。
  launchIntent(q) {
    const raw = String(q || '').trim();
    if (!raw) return '';
    const rest = raw
      .replace(/^(帮我|请|麻烦|给我)*\s*(打开|开启|启动|进入|唤起|召唤|运行|使用|用)?\s*/i, '')
      .replace(/^(?:(?:claude|clode|cloud|克劳德|克劳迪)\s*)?(?:控制台|控制中心|助手|console)?\s*/i, '')
      .replace(/^[的了吧呢啊吗，,。.!！？?\s]+/, '')
      .trim();
    if (!rest) { dlog('launch phrase ignored ' + JSON.stringify(raw)); return ''; }
    // 带着话来的：唤起语后面那部分才是你说的（"打开claude控制台，沙盒在做什么"→"沙盒在做什么"）；
    // 开头压根不是唤起语的，原句原样送。
    const named = /^(帮我|请|麻烦|给我)*\s*(打开|开启|启动|进入|唤起|召唤|运行|使用|用)?\s*(?:(?:claude|clode|cloud|克劳德|克劳迪)\s*)?(?:控制台|控制中心|助手|console)/i.test(raw);
    return named ? rest : raw;
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

  // ---------------------------------------------------------------- 对话内容
  async fetchUnread() {
    const my = this.epoch;
    try {
      const r = await request('GET', '/api/glasses/unread');
      if (my !== this.epoch || r.type === 'none') return;
      this.handle(r, my);
    } catch (e) { dlog('unread failed'); }
  },
  async showLastTurn() {
    const my = this.epoch; this.pager = null;
    try {
      const r = await request('GET', '/api/glasses/history?limit=1&session=' + encodeURIComponent(this.focus.name));
      if (my !== this.epoch) return;
      if (!r.items || !r.items.length) { this.set('idle', { answer: this.focus.name === CONCIERGE ? '单击说话。比如"大家在干嘛""让早鸟对接先发 testing"' : '还没有对话' }); return; }
      // 只显示最新一轮的第一屏；完整内容向后滑看
      const pages = paginate(this.turnText(r.items[r.items.length - 1]));
      this.set('idle', { answer: pages[0] + (pages.length > 1 ? '\n…（向后滑看完整）' : '') });
    } catch (e) {}
  },
  turnText(t) {
    if (t.q === '（主动汇报）') return '【汇报】' + (t.a || '');
    return [t.q ? '你：' + t.q : '', t.a ? this.focus.label + '：' + t.a : ''].filter(Boolean).join('\n\n');
  },
  // 一页放得下就直接显示，放不下进入分页阅读
  showText(text, status) {
    const pages = paginate(text);
    if (pages.length <= 1) { this.pager = null; this.set(status || 'idle', { answer: text }); return; }
    this.pager = { pages: pages, labels: pages.map((_, i) => '第' + (i + 1) + '/' + pages.length + '页'), idx: 0, after: status || 'idle' };
    this.showPage(0);
  },
  async openHistory() {
    const my = this.epoch;
    this.set('thinking', { heard: '', answer: '', hint: '读取历史…' });
    try {
      const r = await request('GET', '/api/glasses/history?limit=20&session=' + encodeURIComponent(this.focus.name));
      if (my === this.epoch) this.enterHistory(r.items);
    } catch (e) { if (my === this.epoch) this.set('error', { hint: String(e.message || e) }); }
  },
  enterHistory(items) {
    if (!items || !items.length) { this.set('idle', { answer: '还没有对话记录', hint: '' }); return; }
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
    this.set('reading', { page: p.labels[p.idx], heard: '', answer: p.pages[p.idx], hint: '' });
    this.setData({ foot: p.labels[p.idx] + ' · ' + (p.idx < p.pages.length - 1 ? '向后滑继续' : '已到最后') + ' · ' + (p.idx > 0 ? '向前滑回看' : '向前滑回到最新') });
  },
  exitPager() {
    const p = this.pager; this.pager = null;
    if (p && p.after === 'confirm') { this.set('confirm', { answer: p.pages[0], hint: '' }); return; }
    this.showLastTurn();
  },

  // ---------------------------------------------------------------- 输入
  onVoiceWakeup(event) { event.preventDefault(); this.listen(); },

  // 真机实测（2026-09-23 日志统计）：
  //   单击 = GlobalHook → Enter（间隔 147–540ms，中位 494）
  //   滑动 = GlobalHook → ArrowRight/Left → ArrowDown/Up（首个方向键 9–345ms）
  //   双击 = GlobalHook ×2 → Backspace（多数宿主直接当系统"退出应用"，不发给页面）
  onKeyDown(event) {
    dlog('key down ' + event.code + ' ' + (event.key || ''));
    const dir = this.swipeDir(event);
    if (!dir) return;
    event.preventDefault();
    this.cancelHook();
    const now = Date.now();
    if (this.lastSwipe && now - this.lastSwipe < 250) return;  // 一次滑动会连发两个方向键
    this.lastSwipe = now;
    this.footNote = '';
    if (this.data.status === 'listening') { this.abortListen(); return; }  // 听的时候滑动 = 放弃这次说话
    if (this.pager) {
      if (dir > 0) this.showPage(this.pager.idx + 1);
      else if (this.pager.idx > 0) this.showPage(this.pager.idx - 1);
      else this.exitPager();
      return;
    }
    if (dir > 0) this.openHistory(); else this.showLastTurn();
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
    // 返回键：在听/在翻页/接通着别人时当"返回"；否则交给系统（退出应用）
    if (event.code === 'Backspace') {
      if (this.data.status !== 'listening' && !this.pager && this.focus.name === CONCIERGE) return;
      event.preventDefault(); this.cancelHook(); this.goBack(); return;
    }
    if (event.code !== 'Enter') return;
    this.cancelHook();
    this.tap();  // 单击：语音识别就在这个事件里同步启动（必须在用户交互当下）
  },
  goBack() {
    dlog('back');
    if (this.data.status === 'listening') { this.abortListen(); return; }
    if (this.pager) { this.exitPager(); return; }
    if (this.focus.name !== CONCIERGE) this.ask('回来');
  },
  cancelHook() { if (this.hookTimer) { clearTimeout(this.hookTimer); this.hookTimer = null; } },
  tap() {
    if (this.data.view === 'pair') { this.startPairing(); return; }
    this.footNote = '';
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
    if (DEV_TEXT === 'true') {
      this.devTurn = (this.devTurn || 0) + 1;
      // 预览测试的台词：只接通沙盒，不碰真实工作会话
      const script = ['接通沙盒', '一句话告诉我3加5等于几', '只读，不要修改任何东西：列出 /home/details-admin/JUSHOOP/workbench 根目录下所有文件和目录名，每个一行，全部放进 detail', '看看历史', '回来'];
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
      this.set('listening', { heard: heard });
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
    this.set('listening', { heard: '', hint: '', answer: '' });
    this.listenTimer = setTimeout(() => {
      this.stopListening();
      // 宿主出错时 onerror/onend 可能都不来：再等 3 秒仍在听就强制复位
      setTimeout(() => { if (this.data.status === 'listening') { this.recognition = null; this.afterListen('识别没有响应，单击重试'); } }, 3000);
    }, LISTEN_TIMEOUT_MS);
    try { r.start(); dlog('sr start() called'); } catch (e) { dlog('sr start() threw ' + (e && (e.name + ' ' + e.message))); this.clearListen(); this.afterListen('无法开始识别：' + (e && e.name)); }
  },

  afterListen(msg) { this.set(this.pendingChat ? 'confirm' : 'idle', { hint: msg }); },
  stopListening() { if (this.recognition) { try { this.recognition.stop(); } catch (e) {} } },
  clearListen() {
    if (this.listenTimer) { clearTimeout(this.listenTimer); this.listenTimer = null; }
    this.recognition = null;
  },

  // ---------------------------------------------------------------- 与 relay 交互
  async ask(text) {
    this.pager = null; this.footNote = '';
    const my = ++this.epoch;
    this.set('thinking', { heard: text, hint: '', answer: '' });
    // 明确带上"发给谁"：relay 重启后记不住当前对象，不能让它猜
    try { this.handle(await request('POST', '/api/glasses/ask', { text: text, session: this.focus.name }), my); }
    catch (e) { if (my === this.epoch) this.set('error', { hint: String(e.message || e) }); }
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
      this.speak(this.focus.label + '想要' + res.description + '，说允许或拒绝');
      return;
    }
    if (res.type === 'working') { this.poll(res.chat_id, res.index, this.epoch); return; }
    if (res.type === 'relay') {
      // 只有出错和"允许/拒绝"的结果值得打断你；其余屏幕上有，不念
      if (res.handled === 'error' || res.handled === 'verdict') this.speak(res.text);
      if (res.handled === 'verdict' && this.pendingChat) {
        const c = this.pendingChat; this.pendingChat = '';
        this.set('thinking', { answer: res.text });
        this.poll(c, this.pendingIndex, this.epoch);
        return;
      }
      if (res.handled === 'history') { this.enterHistory(res.items); return; }
      // 接通 / 回来 / 打开 / 新建：换对象
      if (['switch', 'open', 'back', 'new', 'fork'].indexOf(res.handled) >= 0 && res.session) {
        this.setFocus(res.session, res.label);
        this.refreshOverview();
      }
      this.set(res.handled === 'error' ? 'error' : 'idle', { answer: res.text });
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
.top { color: #00ff00; opacity: 0.7; font-size: 16px; margin-bottom: 8px; padding-left: 14px; }
.main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.ln { display: flex; flex-direction: row; }
.bar { width: 14px; color: #00ff00; font-size: 18px; opacity: 0; }
.tx { flex: 1; color: #00ff00; font-size: 18px; line-height: 1.33; }
.tx.q { opacity: 0.55; font-size: 16px; }
.rule { color: #00ff00; opacity: 0.3; font-size: 12px; padding-left: 14px; overflow: hidden; }
.foot { color: #00ff00; opacity: 0.55; font-size: 14px; font-weight: bold; padding-left: 14px; }  /* 细笔画强光下先糊 */
</style>
