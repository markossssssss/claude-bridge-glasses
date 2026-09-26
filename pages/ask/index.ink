<script def>
{
  "navigationBarTitleText": "Claude 管家",
  "description": "回答用户关于他自己电脑上 Claude Code 开发 agent 的问题：谁在等他决策或确认、某个任务或会话做到哪了、发布到 testing/staging/生产的状态，或把一句指令转达给某个 agent。用户问到这些时调用，把用户原话填进 question。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "question": { "type": "string", "description": "用户的原话，原样传入，不要改写或总结" }
      },
      "required": ["question"]
    }
  },
  "disableScroll": true
}
</script>
<script setup>
// 对话式卡片：系统助手把用户的问题交给这里，这里转给管家，答案显示在系统助手的对话里并念出来。
const BASE = 'https://bridge.jushoop1977.com';
const BUILTIN_TOKEN = '';
const BUILD = '0926-1350';
const DEV_TEXT = 'false';
let TOKEN = '';
try { TOKEN = localStorage.getItem('bridge_token') || BUILTIN_TOKEN; } catch (e) { TOKEN = BUILTIN_TOKEN; }

function log(msg) {
  console.log('[bridge-card] ' + msg);
  if (!TOKEN) return;
  try { wx.request({ url: BASE + '/api/glasses/log?token=' + TOKEN, method: 'POST', header: { 'content-type': 'application/json' }, data: { lines: [{ ts: Date.now(), t: 'card ' + msg }] }, timeout: 10000, success: () => {}, fail: () => {} }); } catch (e) {}
}
function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const opts = { url: BASE + path + (path.indexOf('?') >= 0 ? '&' : '?') + 'token=' + TOKEN, method: method,
      header: { 'content-type': 'application/json' }, timeout: 60000,
      success: (res) => {
        if (!res || res.statusCode !== 200) { reject(new Error('HTTP ' + (res && res.statusCode))); return; }
        let d = res.data;
        if (typeof d === 'string') { try { d = JSON.parse(d); } catch (e) { reject(new Error('bad json')); return; } }
        resolve(d);
      },
      fail: (e) => reject(new Error((e && (e.errMsg || e.message)) || 'network')) };
    if (method !== 'GET') opts.data = body || {};
    wx.request(opts);
  });
}
function toLines(text) {
  return String(text || '').split('\n').slice(0, 9).map((t, i) => ({ id: 'c' + i, t: t || ' ' }));
}

export default {
  data: { title: 'Claude 管家', lines: [], foot: '' },

  onLoad(query) {
    const q = String((query && (query.question || query.text)) || '').trim();
    log('load build=' + BUILD + (DEV_TEXT === 'true' ? ' PREVIEW' : '') + ' q=' + JSON.stringify(q));
    if (!TOKEN) { this.show('还没配对：先打开"Claude 控制台"完成一次配对'); return; }
    if (!q) { this.show('可以问我：谁在等我决策？早鸟对接做到哪了？'); return; }
    this.ask(q);
  },

  show(text, foot) { this.setData({ lines: toLines(text), foot: foot || '' }); },
  speak(text) { try { speechSynthesis.speak(new SpeechSynthesisUtterance(text), 'enqueue'); } catch (e) {} },

  async ask(q) {
    this.show('你：' + q + '\n\n问管家…');
    try {
      let r = await request('POST', '/api/glasses/ask', { text: q, session: 'concierge' });
      for (let i = 0; i < 12 && r && r.type === 'working'; i++) r = await request('GET', '/api/glasses/wait?chat_id=' + r.chat_id + '&after=' + (r.index || 0));
      if (r && r.type === 'reply') {
        this.speak(r.text);
        this.show(r.detail ? r.text + '\n' + r.detail : r.text, r.fixes && r.fixes.length ? '已纠正：' + r.fixes.map((f) => f[0] + '→' + f[1]).join('，') : '');
        log('answered ' + JSON.stringify(r.text));
        return;
      }
      if (r && r.type === 'relay') { this.show(r.text || '已处理'); if (r.handled === 'error') this.speak(r.text); return; }
      this.show('管家还在处理，稍后打开"Claude 控制台"看结果');
    } catch (e) {
      log('failed ' + (e.message || e));
      this.show('连不上管家：' + (e.message || e));
    }
  },
};
</script>
<page>
  <view class="card">
    <text class="title">{{title}}</text>
    <view ink:for="{{lines}}" ink:key="id" class="ln"><text class="tx">{{item.t}}</text></view>
    <text class="foot">{{foot}}</text>
  </view>
</page>
<style>
.card { padding: 10px 12px; background: #000000; display: flex; flex-direction: column; }
.title { color: #00ff00; opacity: 0.7; font-size: 15px; margin-bottom: 6px; }
.ln { display: flex; flex-direction: row; }
.tx { flex: 1; color: #00ff00; font-size: 17px; line-height: 1.35; }
.foot { color: #00ff00; opacity: 0.55; font-size: 13px; margin-top: 4px; }
</style>
