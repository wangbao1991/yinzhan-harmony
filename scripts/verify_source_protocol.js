/*
 * 音源协议兼容性离线自检（不联网、不依赖真机）
 *
 * 用法：node scripts/verify_source_protocol.js
 *
 * 验证八组：
 *   A. lx_bridge.html 的 makeBody 对「对象派 / 字符串派」音源是否都兼容
 *   B. Http.ets detectFormat 对典型无损中转链接的判定是否还会误杀
 *   C. Constants.ets 的音质档位表 / qualityOptions 输出
 *   D. lx_bridge.html 的 __emit 多 handler 竞速与 globalThis.lx 串源隔离
 *   E. Resolver.ets explain() 的失败原因分诊
 *   F. Downloader.ets sniffFormat() 的写盘后文件头验真
 *   G. 运行时能力升级的源码断言（默认 UA / binary / method / 健康度 / 信任音源）
 *   H. 备用链接池与失败换源（抽取 Resolver 的 offerAlternate / takeAlternative / isFatalProbe 真实实现）
 *
 * A/D/E/F/H 直接抽取工程里的真实实现执行，B/C 是等价复刻，G 是源码断言。
 * 不替代真机抓包；真实音源能否取链还取决于第三方接口是否可用。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(ROOT, 'entry/src/main/resources/rawfile/lx_bridge.html'), 'utf8');

// ---- 从桥接页抽出 makeBody 的真实实现，避免这里维护一份会漂移的副本 ----
const start = html.indexOf('function makeBody(');
const end = html.indexOf('/* ---------------- AES ---------------- */');
if (start < 0 || end < 0) {
  throw new Error('未能定位 makeBody，请检查 lx_bridge.html');
}
const makeBodySrc = html.slice(start, end).trim();
const makeBody = new Function('base64ToBytes', makeBodySrc + '\nreturn makeBody;')(() => new Uint8Array(0));

const JSON_BODY = JSON.stringify({
  code: 0,
  data: 'https://cdn.example.com/a.flac?token=x',
  url: 'https://cdn.example.com/a.flac',
  updateMsg: '有新版本'
});
const HTML_BODY = '<html><body>403 Forbidden</body></html>';

console.log('===== A. resp.body 双兼容 =====');
const cases = [
  ['ikun / huibq 对象派 (body.code)', (b) => {
    if (!b || isNaN(Number(b.code))) throw new Error('unknow error');
    return 'code=' + b.code;
  }],
  ['juhe 对象派 (r.body.data)', (b) => {
    if (!b || !b.data) throw new Error('body.data 缺失');
    return 'data ok';
  }],
  ['星海 对象派 (resp.body.url)', (b) => {
    if (!b || !b.url) throw new Error('body.url 缺失');
    return b.url.slice(0, 28) + '...';
  }],
  ['全豆要 / 聚合 字符串派 (body.trim + JSON.parse)', (b) => {
    const t = b.trim();
    const o = JSON.parse(t);
    return 'parse ok, code=' + o.code;
  }],
  ['星海 Buffer 兼容 (body.toString("utf-8"))', (b) => {
    if (typeof b.toString === 'function' && b.toString() !== '[object Object]') {
      b = b.toString('utf-8');
    }
    return 'toString ok, len=' + b.length;
  }]
];
let failures = 0;
for (const [name, fn] of cases) {
  let before;
  let after;
  try { before = 'OK ' + fn(JSON_BODY); } catch (e) { before = 'FAIL ' + e.message; }
  try { after = 'OK ' + fn(makeBody(JSON_BODY, { 'content-type': 'application/json; charset=utf-8' })); }
  catch (e) { after = 'FAIL ' + e.message; }
  if (after.startsWith('FAIL')) failures++;
  console.log(`  ${name}\n    修复前(原始字符串): ${before}\n    修复后(makeBody)  : ${after}`);
}
const htmlBody = makeBody(HTML_BODY, { 'content-type': 'text/html' });
console.log(`  非 JSON 响应保持字符串: ${typeof htmlBody === 'string' ? 'OK' : 'FAIL'} (${typeof htmlBody})`);
if (typeof htmlBody !== 'string') failures++;

// ---- B. detectFormat 等价复刻（含本轮新增的查询参数线索） ----
console.log('\n===== B. 格式判定（Http.ets detectFormat 等价复刻） =====');
function detectFormat(type, url, size, durationSec) {
  const t = type.toLowerCase();
  if (t.includes('flac')) return 'flac';
  if (t.includes('mpeg') || t.includes('mp3')) return 'mp3';
  if (t.includes('mp4') || t.includes('m4a') || t.includes('aac')) return 'm4a';
  if (t.includes('ogg') || t.includes('opus')) return 'ogg';
  if (t.includes('wav')) return 'wav';
  const u = url.toLowerCase();
  const cut = u.indexOf('?');
  const p = cut >= 0 ? u.substring(0, cut) : u;
  if (p.endsWith('.flac')) return 'flac';
  if (p.endsWith('.mp3')) return 'mp3';
  if (p.endsWith('.m4a') || p.endsWith('.mp4') || p.endsWith('.aac')) return 'm4a';
  if (p.endsWith('.ogg') || p.endsWith('.opus')) return 'ogg';
  if (p.endsWith('.wav')) return 'wav';
  // 本轮新增：中转 / 聚合 API 把格式写在查询参数里
  const q = cut >= 0 ? u.substring(cut + 1) : '';
  if (q.includes('type=mp3') || q.includes('level=mp3') || q.includes('quality=128') || q.includes('br=128')) return 'mp3';
  if (q.includes('flac') || q.includes('lossless') || q.includes('hires') || q.includes('24bit') ||
    q.includes('master') || q.includes('atmos') || q.includes('br=999')) return 'flac';
  if (size > 0 && durationSec > 0) {
    const kbps = size * 8 / durationSec / 1000;
    if (kbps >= 500) return 'flac';
    if (kbps >= 160) return 'mp3';
  }
  return 'unknown';
}
const links = [
  ['audio/flac + .flac 直链', 'audio/flac', 'https://cdn.x.com/a.flac'],
  ['octet-stream + 无后缀中转', 'application/octet-stream', 'https://api.x.com/url?id=123'],
  ['octet-stream + ?type=flac&level=hires', 'application/octet-stream', 'https://api.x.com/wy.php?type=flac&level=hires&id=1'],
  ['octet-stream + ?br=999 (24bit)', 'application/octet-stream', 'https://api.x.com/get?br=999&id=1'],
  ['octet-stream + ?type=mp3', 'application/octet-stream', 'https://api.x.com/get?type=mp3&id=1'],
  ['audio/mpeg 头（真 mp3）', 'audio/mpeg', 'https://api.x.com/get?id=1'],
  ['防盗链返回 HTML', 'text/html', 'https://api.x.com/get?id=1']
];
for (const [name, type, url] of links) {
  const fmt = detectFormat(type, url, 0, 0);
  // Resolver 的新严格规则：无损请求只拒绝「明确有损」的证据
  const lossy = fmt === 'mp3' || fmt === 'm4a' || fmt === 'ogg';
  const verdict = type.includes('html') ? '拒绝(前置拦截: 返回不是音频)' :
    (lossy ? '拒绝(明确有损)' : '放行');
  console.log(`  ${name.padEnd(38)} format=${fmt.padEnd(8)} ${verdict}`);
}

// ---- C. 音质档位表 ----
console.log('\n===== C. 音质档位表 =====');
const QUALITY_ORDER = ['master', 'atmos_plus', 'atmos', 'hires', 'flac24bit', 'flac', '320k', '192k', '128k'];
const BASE = ['flac24bit', 'flac', '320k', '192k', '128k'];
function normalizeQuality(q) {
  const s = (q || '').trim().toLowerCase();
  if (['24bit', 'flac24', 'flac24b'].includes(s)) return 'flac24bit';
  if (['hi-res', 'hi_res', 'hires24bit'].includes(s)) return 'hires';
  if (['atmosplus', 'atmos+'].includes(s)) return 'atmos_plus';
  if (s === 'dolby') return 'atmos';
  return s;
}
function qualityOptions(declared) {
  const all = declared.concat(BASE);
  const norm = [];
  for (const q of all) {
    const n = normalizeQuality(q);
    if (QUALITY_ORDER.includes(n) && !norm.includes(n)) norm.push(n);
  }
  return QUALITY_ORDER.filter(q => norm.includes(q));
}
console.log('  未导入音源 / 基础档   :', qualityOptions([]).join(' > '));
console.log('  导入杰翔(声明母带等) :', qualityOptions(['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master']).join(' > '));
console.log('  导入旧版全豆要(24bit):', qualityOptions(['24bit', 'flac', '320k', '192k', '128k']).join(' > '));
console.log('  别名 24bit 归一化    :', normalizeQuality('24bit'));

// ---- D~G：本轮「运行时能力对齐」的真实实现级回归 ----
const resolverSrc = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/core/Resolver.ets'), 'utf8');
const downloaderSrc = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/core/Downloader.ets'), 'utf8');
const runnerSrc = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/core/LxRunner.ets'), 'utf8');
const playerSrc = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/core/Player.ets'), 'utf8');
const sourcesPageSrc = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/ui/pages/SourcesPage.ets'), 'utf8');

(async () => {
  console.log('\n===== D. request 多 handler 竞速 / globalThis.lx 隔离（抽取 __emit 真实实现） =====');
  const emitStart = html.indexOf('    __emit: function');
  const emitEnd = html.indexOf('    __httpResolve: function');
  if (emitStart < 0 || emitEnd < 0) throw new Error('未能定位 __emit，请检查 lx_bridge.html');
  const emitSrc = html.slice(emitStart, emitEnd).trim();
  const buildHost = new Function('instances', 'EVENT_NAMES', 'toNative', 'createLx', 'windowRef', 'baseLx', `
    var window = windowRef;
    var lxCallCount = 0;
    var host = { ${emitSrc} };
    return host;
  `);

  function emitCase(handlers) {
    return new Promise((resolve) => {
      const messages = [];
      const instLx = { tag: 'own' };
      const baseLx = { tag: 'base' };
      const windowRef = { lx: baseLx };
      const instances = { s1: { handlers: { request: handlers }, lx: instLx } };
      const state = { duringCall: null };
      const all = [() => { state.duringCall = windowRef.lx; return Promise.resolve({}); }].concat(handlers);
      instances.s1.handlers.request = all;
      const host = buildHost(instances, { request: 'request' }, (m) => messages.push(m),
        () => instLx, windowRef, baseLx);
      host.__emit('s1', 'musicUrl', 'q1', JSON.stringify({ action: 'musicUrl', info: {} }));
      setTimeout(() => resolve({ messages: messages, state: state, windowRef: windowRef, instLx: instLx, baseLx: baseLx }), 20);
    });
  }
  function check(name, cond, detail) {
    if (!cond) failures++;
    console.log(`  ${cond ? 'OK  ' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);
  }

  const r1 = await emitCase([
    () => Promise.resolve({}),
    () => { throw new Error('子音源挂了'); },
    () => Promise.resolve({ url: 'https://cdn.x.com/a.flac' })
  ]);
  const okMsg = r1.messages.find((m) => m.type === 'result' && m.ok);
  check('3 个 handler：空返回 / 抛错 / 有效链接 → 取有效那个',
    !!okMsg && String(okMsg.dataText).includes('a.flac'),
    okMsg ? String(okMsg.dataText).slice(0, 42) : '无成功结果');

  const r2 = await emitCase([() => Promise.resolve({}), () => Promise.resolve({})]);
  check('全部返回空对象 → 明确报错而不是静默成功',
    r2.messages.some((m) => m.type === 'result' && !m.ok));

  const r3 = await emitCase([() => Promise.resolve({ url: 'https://x/a' })]);
  check('调用期间 globalThis.lx 指向本实例', r3.state.duringCall === r3.instLx);
  check('调用结束后恢复基准实例（不串到首选）', r3.windowRef.lx === r3.baseLx);

  console.log('\n===== E. 失败原因分诊（抽取 Resolver.explain 真实实现） =====');
  const exMatch = resolverSrc.match(/private static explain\(text: string\): string \{([\s\S]*?)\n  \}/);
  if (!exMatch) throw new Error('未能定位 Resolver.explain');
  const explain = new Function('return function explain(text) {' + exMatch[1] + '\n};')();
  const diag = [
    ['后端失败: 后端聚合接口返回403，已屏蔽', '403'],
    ['FLAC：HTTP 404', '404'],
    ['接口已失效（404）', '404'],
    ['请求过于频繁（429）', '429'],
    ['音源响应超时', '超时'],
    ['返回的不是音频', '不是音频'],
    ['只给到128K（mp3 128kbps）', '只给到']
  ];
  for (const [raw, keyword] of diag) {
    const out = explain(raw);
    check(`「${raw.slice(0, 24)}」→ ${out}`, out.includes(keyword));
  }

  console.log('\n===== F. 写盘后文件头验真（抽取 Downloader.sniffFormat 真实实现） =====');
  const sniffMatch = downloaderSrc.match(/private static sniffFormat\(path: string\): string \{([\s\S]*?)\n  \}/);
  if (!sniffMatch) throw new Error('未能定位 Downloader.sniffFormat');
  let current = new Uint8Array(16);
  const mockFs = {
    OpenMode: { READ_ONLY: 0 },
    openSync: () => ({ fd: 1 }),
    readSync: (fd, buf) => { new Uint8Array(buf).set(current); },
    closeSync: () => {}
  };
  const sniff = new Function('fs', 'return function sniffFormat(path) {' + sniffMatch[1] + '\n};')(mockFs);
  function withBytes(list) {
    current = new Uint8Array(16);
    current.set(list);
    return sniff('/tmp/fake.bin');
  }
  const magic = [
    ['fLaC → flac', [0x66, 0x4C, 0x61, 0x43], 'flac'],
    ['ID3 → mp3', [0x49, 0x44, 0x33], 'mp3'],
    ['MPEG 帧同步 → mp3', [0xFF, 0xFB, 0x90, 0x00], 'mp3'],
    ['OggS → ogg', [0x4F, 0x67, 0x67, 0x53], 'ogg'],
    ['RIFF....WAVE → wav', [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45], 'wav'],
    ['....ftyp → m4a', [0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70], 'm4a'],
    ['<html → html（错误页）', [0x3C, 0x68, 0x74, 0x6D, 0x6C], 'html'],
    ['{"code" → json（错误体）', [0x7B, 0x22, 0x63, 0x6F], 'json'],
    ['加密流 → unknown', [0xAA, 0xBB, 0xCC, 0xDD], 'unknown']
  ];
  for (const [name, list, expected] of magic) {
    const got = withBytes(list);
    check(name, got === expected, 'got=' + got);
  }

  console.log('\n===== G. 运行时能力升级源码断言 =====');
  const asserts = [
    ['LxRunner 补官方默认 UA', runnerSrc.includes("'lx-music-mobile/1.7.0'")],
    ['LxRunner 补默认 Accept', runnerSrc.includes("headers['Accept'] = '*/*'")],
    ['LxRunner 支持 ARRAY_BUFFER', runnerSrc.includes('http.HttpDataType.ARRAY_BUFFER')],
    ['LxRunner 补全 DELETE / HEAD / OPTIONS', runnerSrc.includes("case 'DELETE'") && runnerSrc.includes("case 'HEAD'")],
    ['LxRunner PATCH 覆盖头', runnerSrc.includes('X-HTTP-Method-Override')],
    ['LxRunner binary 回传', runnerSrc.includes('payload.binary = true')],
    ['Resolver 单源超时放宽到 12s', resolverSrc.includes('const SOURCE_TIMEOUT: number = 12000')],
    ['Resolver 音源健康度降权', resolverSrc.includes('HEALTH_COOLDOWN_MS')],
    ['Resolver 首选连续失败强制补位', resolverSrc.includes('autoFallbackOnFailure')],
    ['Resolver 默认信任音源', resolverSrc.includes('verifyBeforeDownload')],
    ['Downloader 落盘后验文件头', downloaderSrc.includes('const sniff = Downloader.sniffFormat(tempPath)')],
    ['桥接页 __emit 遍历所有 handler', html.includes('for (var i = 0; i < handlers.length; i++)')]
  ];
  for (const [name, cond] of asserts) check(name, cond);

  console.log('\n===== H. 备用链接池与失败换源（抽取 Resolver 真实实现） =====');
  const offerMatch = resolverSrc.match(
    /private offerAlternate\(song: SongInfo,[\s\S]*?verified: boolean\): void \{([\s\S]*?)\n  \}/);
  const takeMatch = resolverSrc.match(
    /takeAlternative\(song: SongInfo, failedUrl: string\): ResolveResult \| null \{([\s\S]*?)\n  \}/);
  const fatalMatch = resolverSrc.match(
    /private static isFatalProbe\(reason: string\): boolean \{([\s\S]*?)\n  \}/);
  if (!offerMatch || !takeMatch || !fatalMatch) {
    throw new Error('未能定位备用链接池实现，请检查 Resolver.ets');
  }
  // 只剥掉 ArkTS 的类型注解，方法体逻辑保持与工程里完全一致
  const offerBody = offerMatch[1]
    .replace('(a: Alternate, b: Alternate): number =>', '(a, b) =>');
  const takeBody = takeMatch[1]
    .replace('(item: CacheItem, cacheKey: string): void =>', '(item, cacheKey) =>')
    .replace('const alive: Alternate[] = [];', 'const alive = [];');
  const marks = [];
  const ResolverStub = {
    alternateKey: (s) => s.id + '@' + s.source,
    markFail: (id, platform, reason) => marks.push([id, platform, reason]),
    penalty: () => 0
  };
  const offer = new Function('Resolver', 'ALTERNATE_TTL', 'ALTERNATE_MAX',
    'return function offerAlternate(song, item, result, verified) {' + offerBody + '\n};')(
      ResolverStub, 90000, 12);
  const take = new Function('Resolver',
    'return function takeAlternative(song, failedUrl) {' + takeBody + '\n};')(ResolverStub);
  const isFatal = new Function('return function isFatalProbe(reason) {' + fatalMatch[1] + '\n};')();

  const host = { cache: new Map(), alternates: new Map() };
  const song = { id: 's1', source: 'wy' };
  // 模拟 12 个音源都给了链接，只有第 3 / 7 条探测通过
  for (let i = 0; i < 12; i++) {
    offer.call(host, song, { id: 'src' + i.toString(), name: '源' + i.toString() },
      { url: 'https://cdn/x/' + i.toString() + '.flac', from: '源' + i.toString(),
        quality: 'flac', format: 'flac', kbps: 900, headers: {} },
      i === 3 || i === 7);
  }
  check('12 条链接全部保留，不再因竞速落选被丢弃',
    host.alternates.get('s1@wy').length === 12);
  check('探测通过的两条排在前面（换源优先挑可用的）',
    host.alternates.get('s1@wy').slice(0, 2).every((a) => a.verified));

  host.cache.set('cache1', { url: 'https://cdn/x/0.flac' });
  const alt1 = take.call(host, song, 'https://cdn/x/0.flac');
  check('首条 prepare 失败后换到探测通过的链接', alt1 !== null && alt1.from === '源3');
  check('失败链接对应的音源被降权记录',
    marks.length === 1 && marks[0][2] === '播放准备失败');
  check('失败链接的缓存被清除，不会下次又先拿到它', host.cache.size === 0);
  const alt2 = take.call(host, song, alt1.url);
  check('第二次换源拿到另一条可用链接', alt2 !== null && alt2.from === '源7');
  const alt3 = take.call(host, song, alt2.url);
  check('可用链接用完后仍会试未探测的链接（信任音源）',
    alt3 !== null && alt3.url.indexOf('.flac') > 0);
  let guard = 0;
  let last = alt3;
  while (last !== null && guard < 20) {
    last = take.call(host, song, last.url);
    guard++;
  }
  check('备用链接逐条取完后返回 null（不会死循环）', last === null && guard <= 12);

  const fatalCases = [
    ['HTTP 403', true], ['HTTP 404', true], ['HTTP 500', true],
    ['返回的不是音频', true], ['只有 300KB，是试听片段', true],
    ['不是网络地址', true], ['跳转无地址', true], ['跳转次数过多', true],
    ['HTTP 0', false], ['', false], ['请求失败', false]
  ];
  for (const [reason, want] of fatalCases) {
    check(`探测「${reason || '(空)'}」→ ${want ? '淘汰坏链接' : '仍信任音源'}`,
      isFatal(reason) === want);
  }

  const hAsserts = [
    ['Resolver 保留所有候选链接', resolverSrc.includes('private offerAlternate(')],
    ['Resolver 提供失败换源接口', resolverSrc.includes('takeAlternative(song: SongInfo')],
    ['Resolver 播放路径淘汰坏链接', resolverSrc.includes('Resolver.isFatalProbe(probe.reason)')],
    ['Resolver 单源场景不误杀', resolverSrc.includes('const lenient: boolean = candidates.length === 1')],
    ['Resolver 失败提示标注参与音源数', resolverSrc.includes('个音源参与取链')],
    ['Player 播放失败自动换源', playerSrc.includes('Resolver.get().takeAlternative(this.current, this.lastUrl)')],
    ['Player 换源次数上限 3', playerSrc.includes('const MAX_SOURCE_SWITCH: number = 3')],
    ['Player 切歌重置换源计数', playerSrc.includes('this.switchCount = 0')],
    ['音源页显示已启用 / 已加载统计', sourcesPageSrc.includes('private sourceStat()')]
  ];
  for (const [name, cond] of hAsserts) check(name, cond);

  console.log(`\n结论：${failures === 0 ? '全部通过' : failures + ' 项失败'}`);
  process.exit(failures === 0 ? 0 : 1);
})();
