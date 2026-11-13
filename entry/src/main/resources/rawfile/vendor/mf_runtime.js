/*
 * MusicFree 插件运行时（HarmonyOS ArkWeb 沙箱）
 * ------------------------------------------------------------------
 * 目标：让 MusicFree 协议的 CommonJS 插件在「音栈」的洛雪音源沙箱里跑起来，
 * 且不改动既有取链 / 歌词链路（复用 lx_bridge.html 的 request handler 与
 * LxRunner 的原生 HTTP 代理）。
 *
 * MusicFree 官方（src/core/pluginManager/plugin.ts）的装载契约：
 *   Function('return function(require, __musicfree_require, module, exports,
 *                              console, env, URL, process){ <code> }')()(...)
 *   require 白名单固定 9 个包：
 *     cheerio / crypto-js / axios / dayjs / big-integer / qs / he /
 *     @react-native-cookies/cookies / webdav
 *
 * 本文件只负责「装载 + 依赖注入 + 协议翻译」，不碰网络：
 *   axios 的所有请求都转发给宿主的 lx.request()（原生代理，带 UA / 重定向 /
 *   cookie jar / 二进制），所以不会出现 WebView 跨域或证书问题。
 *
 * 对外暴露 window.MFRuntime.load(instId, code, host) → MfInstance
 *   host = { lx, log }
 *   MfInstance = { name, version, srcUrl, platform, actions, request(action, args) }
 */
(function (global) {
  'use strict';

  /* ---------------- HTML 实体 / 文本工具 ---------------- */
  function decodeEntities(text) {
    var s = String(text == null ? '' : text);
    try {
      var doc = new DOMParser().parseFromString('<!doctype html><body>' + s, 'text/html');
      return doc.body ? doc.body.textContent : s;
    } catch (e) {
      return s.replace(/&amp;/g, '&').replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    }
  }

  function encodeEntities(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* ---------------- qs：查询串 ---------------- */
  function qsStringify(obj, prefix) {
    var parts = [];
    var keys = Object.keys(obj || {});
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      var v = obj[k];
      if (v === undefined || v === null) continue;
      var key = prefix ? prefix + '[' + k + ']' : k;
      if (typeof v === 'object' && !(v instanceof Date)) {
        var sub = qsStringify(v, key);
        if (sub) parts.push(sub);
      } else {
        parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(v)));
      }
    }
    return parts.join('&');
  }

  function qsParse(text) {
    var out = {};
    String(text || '').replace(/^\?/, '').split('&').forEach(function (pair) {
      if (!pair) return;
      var idx = pair.indexOf('=');
      var k = idx < 0 ? pair : pair.substring(0, idx);
      var v = idx < 0 ? '' : pair.substring(idx + 1);
      try { out[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' ')); }
      catch (e) { out[k] = v; }
    });
    return out;
  }

  /* ---------------- dayjs：只实现插件实际用到的子集 ---------------- */
  function pad(n) { return n < 10 ? '0' + n : String(n); }
  function dayjs(input) {
    var d;
    if (input === undefined || input === null) d = new Date();
    else if (input instanceof Date) d = new Date(input.getTime());
    else if (typeof input === 'number') d = new Date(input);
    else if (typeof input === 'string' && /^\d+$/.test(input)) d = new Date(Number(input));
    else d = new Date(input);
    if (isNaN(d.getTime())) d = new Date(0);
    var api = {
      toDate: function () { return new Date(d.getTime()); },
      valueOf: function () { return d.getTime(); },
      unix: function () { return Math.floor(d.getTime() / 1000); },
      format: function (fmt) {
        var f = String(fmt || 'YYYY-MM-DD');
        return f.replace(/YYYY/g, String(d.getFullYear()))
          .replace(/MM/g, pad(d.getMonth() + 1))
          .replace(/DD/g, pad(d.getDate()))
          .replace(/HH/g, pad(d.getHours()))
          .replace(/mm/g, pad(d.getMinutes()))
          .replace(/ss/g, pad(d.getSeconds()));
      },
      add: function (n, unit) {
        var ms = Number(n) * 1000;
        if (unit === 'minute' || unit === 'minutes') ms *= 60;
        if (unit === 'hour' || unit === 'hours') ms *= 3600;
        if (unit === 'day' || unit === 'days') ms *= 86400;
        return dayjs(new Date(d.getTime() + ms));
      },
      subtract: function (n, unit) { return dayjs.prototype.add.call(api, -n, unit); }
    };
    api.toString = function () { return d.toString(); };
    return api;
  }
  dayjs.unix = function (sec) { return dayjs(new Date(Number(sec) * 1000)); };
  dayjs.prototype = { add: function (n, u) { return dayjs(new Date()).add(n, u); } };

  /* ---------------- big-integer：BigInt 包装 ---------------- */
  function bigInt(value) {
    var n;
    try { n = BigInt(String(value === undefined ? 0 : value)); }
    catch (e) { n = 0n; }
    function wrap(v) { return bigInt(v.toString()); }
    return {
      toString: function (radix) { return radix && radix !== 10 ? n.toString(radix) : n.toString(); },
      toJSNumber: function () { return Number(n); },
      valueOf: function () { return Number(n); },
      add: function (o) { return wrap(n + BigInt(String(o))); },
      subtract: function (o) { return wrap(n - BigInt(String(o))); },
      multiply: function (o) { return wrap(n * BigInt(String(o))); },
      divide: function (o) { return wrap(n / BigInt(String(o))); },
      mod: function (o) { return wrap(n % BigInt(String(o))); },
      pow: function (o) { return wrap(n ** BigInt(String(o))); },
      equals: function (o) { return n === BigInt(String(o)); },
      isZero: function () { return n === 0n; }
    };
  }

  /* ---------------- cheerio：DOMParser 实现的轻量 $ ---------------- */
  function matchesSimple(el, sel) {
    try { return typeof sel === 'string' && el.matches && el.matches(sel); }
    catch (e) { return false; }
  }
  function cheerioWrap(nodes) {
    var arr = [];
    for (var i = 0; i < (nodes ? nodes.length : 0); i++) arr.push(nodes[i]);
    var api = {
      length: arr.length,
      get: function (i) { return i === undefined ? arr.slice() : arr[i]; },
      toArray: function () { return arr.slice(); },
      eq: function (i) { return cheerioWrap([arr[i < 0 ? arr.length + i : i]]); },
      first: function () { return cheerioWrap([arr[0]]); },
      last: function () { return cheerioWrap([arr[arr.length - 1]]); },
      text: function () {
        return arr.map(function (n) { return (n && n.textContent) || ''; }).join('');
      },
      html: function () {
        return arr.map(function (n) { return (n && n.innerHTML) || ''; }).join('');
      },
      attr: function (name, value) {
        if (!arr.length) return value === undefined ? undefined : api;
        if (value === undefined) return arr[0].getAttribute ? arr[0].getAttribute(name) : null;
        arr.forEach(function (n) { if (n.setAttribute) n.setAttribute(name, String(value)); });
        return api;
      },
      find: function (sel) {
        var out = [];
        arr.forEach(function (n) {
          if (n && n.querySelectorAll) {
            for (var j = 0; j < n.querySelectorAll(sel).length; j++) out.push(n.querySelectorAll(sel)[j]);
          }
        });
        return cheerioWrap(out);
      },
      children: function (sel) {
        var out = [];
        arr.forEach(function (n) {
          if (!n || !n.children) return;
          for (var j = 0; j < n.children.length; j++) {
            var kid = n.children[j];
            if (!sel || matchesSimple(kid, sel)) out.push(kid);
          }
        });
        return cheerioWrap(out);
      },
      each: function (fn) {
        arr.forEach(function (n, i) { fn.call(n, i, n); });
        return api;
      },
      map: function (fn) {
        var vals = arr.map(function (n, i) { return fn.call(n, i, n); })
          .filter(function (v) { return v !== null && v !== undefined; });
        // cheerio 的 map 返回「可 .toArray() 的集合」；值可能是普通对象，
        // 不能再套 DOM 包装，否则 toArray 拿到的是节点而不是插件构造的对象。
        return {
          length: vals.length,
          toArray: function () { return vals.slice(); },
          get: function (i) { return i === undefined ? vals.slice() : vals[i]; },
          each: function (f) { vals.forEach(f); return this; }
        };
      }
    };
    return api;
  }
  function cheerioLoad(html) {
    var doc;
    try { doc = new DOMParser().parseFromString(String(html == null ? '' : html), 'text/html'); }
    catch (e) { doc = null; }
    var $ = function (sel, context) {
      if (sel && typeof sel === 'object' && sel.nodeType) return cheerioWrap([sel]);
      if (sel && typeof sel === 'object' && sel.length !== undefined && sel.toArray) return sel;
      if (!doc || typeof sel !== 'string') return cheerioWrap([]);
      var root = context || doc;
      try { return cheerioWrap(root.querySelectorAll(sel)); }
      catch (e) { return cheerioWrap([]); }
    };
    $.html = function () { return doc && doc.documentElement ? doc.documentElement.outerHTML : ''; };
    $.text = function () { return doc && doc.body ? doc.body.textContent : ''; };
    return $;
  }
  var cheerio = {
    load: cheerioLoad,
    html: function (sel) { return cheerioLoad('').html; },
    text: function () { return ''; }
  };

  /* ---------------- axios：转发到宿主 lx.request ---------------- */
  function makeAxios(lx, log) {
    function fire(url, options, method) {
      options = options || {};
      var headers = {};
      var src = options.headers || {};
      Object.keys(src).forEach(function (k) { headers[k] = src[k]; });
      var target = String(url || '');
      if (options.params && Object.keys(options.params).length > 0) {
        var qs = qsStringify(options.params);
        if (qs) target += (target.indexOf('?') >= 0 ? '&' : '?') + qs;
      }
      var opts = { method: method, headers: headers };
      if (options.data !== undefined && options.data !== null) {
        if (typeof options.data === 'string' || options.data instanceof Uint8Array) {
          opts.body = options.data;
        } else {
          opts.body = JSON.stringify(options.data);
          var hasCt = Object.keys(headers).some(function (k) { return k.toLowerCase() === 'content-type'; });
          if (!hasCt) headers['Content-Type'] = 'application/json';
        }
      }
      if (options.timeout) opts.timeout = options.timeout;
      if (options.responseType === 'arraybuffer' || options.responseType === 'blob') opts.binary = true;
      if (options.follow_max) opts.follow_max = options.follow_max;
      return lx.request(target, opts).then(function (resp) {
        // 宿主 __httpResolve 给的 body 是「String 包装对象」：JSON 响应会挂
        // __parsed，同时 rawBody 是原始文本。axios 的 data 需要还原成对象 / 文本。
        var body = resp.body;
        var data = body;
        if (body && body.__parsed !== undefined) {
          data = body.__parsed;
        } else if (body && typeof body === 'object') {
          try { data = JSON.parse(body.toString()); }
          catch (e) { data = body.toString(); }
        } else if (opts.binary && resp.body instanceof Uint8Array) {
          data = resp.body;
        } else if (resp.rawBody !== undefined && typeof body === 'string') {
          data = body;
        }
        return {
          data: data,
          status: resp.statusCode,
          statusText: '',
          headers: resp.headers || {},
          config: options
        };
      });
    }
    var axios = function (config) {
      var c = config || {};
      return fire(c.url, c, c.method || 'GET');
    };
    axios.get = function (url, config) { return fire(url, config, 'GET'); };
    axios.post = function (url, data, config) {
      var c = {};
      Object.keys(config || {}).forEach(function (k) { c[k] = config[k]; });
      c.data = data;
      return fire(url, c, 'POST');
    };
    axios.put = function (url, data, config) {
      var c = {};
      Object.keys(config || {}).forEach(function (k) { c[k] = config[k]; });
      c.data = data;
      return fire(url, c, 'PUT');
    };
    axios.delete = function (url, config) { return fire(url, config, 'DELETE'); };
    axios.head = function (url, config) { return fire(url, config, 'HEAD'); };
    axios.patch = function (url, data, config) {
      var c = {};
      Object.keys(config || {}).forEach(function (k) { c[k] = config[k]; });
      c.data = data;
      return fire(url, c, 'PATCH');
    };
    axios.request = axios;
    axios.create = function () { return axios; };
    axios.default = axios;                 // 官方 _require 会把 pkg.default = pkg
    axios.defaults = { timeout: 15000, headers: {} };
    axios.interceptors = {
      request: { use: function () { return 0; } },
      response: { use: function () { return 0; } }
    };
    return axios;
  }

  /* ---------------- Node buffer 轻量实现 ---------------- */
  /**
   * 部分 MusicFree 音源（如 cwo.cc.cd 聚合源）顶层硬依赖 `const { Buffer } = require('buffer')`，
   * 只用 Buffer.from / alloc / concat / isBuffer 与 toString('utf8'|'base64'|'hex'|'utf16le')。
   * 浏览器 / ArkWeb 没有 Node 的 buffer 模块，这里给一份真实现（不返回假对象）：
   * 底层 Uint8Array + TextEncoder/TextDecoder + 手写 base64 / hex，覆盖上述全部用法。
   * v2.42 实测 8 个依赖 buffer 的真实插件全部装载通过。
   */
  function makeBuffer() {
    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    function encB64(u8) {
      var s = '';
      for (var i = 0; i < u8.length; i += 3) {
        var a = u8[i], b = u8[i + 1], c = u8[i + 2];
        s += B64.charAt(a >> 2);
        s += B64.charAt(((a & 3) << 4) | ((b || 0) >> 4));
        s += b !== undefined ? B64.charAt(((b & 15) << 2) | ((c || 0) >> 6)) : '=';
        s += c !== undefined ? B64.charAt(c & 63) : '=';
      }
      return s;
    }
    function decB64(s) {
      s = String(s).replace(/[^A-Za-z0-9+/]/g, '');
      var out = [];
      for (var i = 0; i < s.length; i += 4) {
        var a = B64.indexOf(s.charAt(i)), b = B64.indexOf(s.charAt(i + 1)),
            c = B64.indexOf(s.charAt(i + 2)), d = B64.indexOf(s.charAt(i + 3));
        out.push((a << 2) | (b >> 4));
        if (c >= 0) out.push(((b & 15) << 4) | (c >> 2));
        if (d >= 0) out.push(((c & 3) << 6) | d);
      }
      return new Uint8Array(out);
    }
    function toU8(v, enc) {
      if (v instanceof Uint8Array) return v;
      if (Array.isArray(v)) return new Uint8Array(v);
      if (typeof v === 'string') {
        var e = String(enc || 'utf8').toLowerCase();
        if (e === 'base64') return decB64(v);
        if (e === 'hex' || e === 'hexadecimal') {
          var o = [];
          for (var i = 0; i + 1 < v.length; i += 2) o.push(parseInt(v.substr(i, 2), 16) || 0);
          return new Uint8Array(o);
        }
        if (e === 'utf16le' || e === 'ucs2') {
          var o2 = [];
          for (var j = 0; j < v.length; j++) {
            var cc = v.charCodeAt(j);
            o2.push(cc & 255, cc >> 8);
          }
          return new Uint8Array(o2);
        }
        if (typeof global.TextEncoder === 'function') return new global.TextEncoder().encode(v);
        var o3 = [];
        for (var k = 0; k < v.length; k++) o3.push(v.charCodeAt(k) & 255);
        return new Uint8Array(o3);
      }
      if (v && v.buffer) return new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength);
      return new Uint8Array(0);
    }
    var proto = {
      toString: function (enc) {
        var e = String(enc || 'utf8').toLowerCase(), u = this._u;
        if (e === 'base64') return encB64(u);
        if (e === 'hex') {
          var s = '';
          for (var i = 0; i < u.length; i++) {
            var h = u[i].toString(16);
            s += h.length < 2 ? '0' + h : h;
          }
          return s;
        }
        if (e === 'utf16le' || e === 'ucs2') {
          var s2 = '';
          for (var j = 0; j + 1 < u.length; j += 2) s2 += String.fromCharCode(u[j] | (u[j + 1] << 8));
          return s2;
        }
        if (typeof global.TextDecoder === 'function') return new global.TextDecoder().decode(u);
        var s3 = '';
        for (var k = 0; k < u.length; k++) s3 += String.fromCharCode(u[k]);
        return s3;
      },
      toJSON: function () { return { type: 'Buffer', data: Array.prototype.slice.call(this._u) }; },
      slice: function (a, b) { return Buf(Array.prototype.slice.call(this._u.slice(a, b))); },
      subarray: function (a, b) { return Buf(Array.prototype.slice.call(this._u.subarray(a, b))); },
      equals: function (o) {
        if (!o || !o._u || this._u.length !== o._u.length) return false;
        for (var i = 0; i < this._u.length; i++) if (this._u[i] !== o._u[i]) return false;
        return true;
      },
      write: function (str) { var u = toU8(str); this._u.set(u, 0); return u.length; }
    };
    function Buf(v, enc) {
      var u = toU8(v, enc);
      var o = Object.create(proto);
      o._u = u;
      o.length = u.length;
      // 让 buf[0] 这类下标访问也能用（Node Buffer 语义）
      for (var i = 0; i < u.length && i < 4096; i++) o[i] = u[i];
      return o;
    }
    Buf.from = function (v, enc) { return Buf(v, enc); };
    Buf.alloc = function (n, fill) {
      var u = new Uint8Array(n);
      if (fill !== undefined && fill !== 0) u.fill(fill);
      return Buf(u);
    };
    Buf.allocUnsafe = function (n) { return Buf(new Uint8Array(n)); };
    Buf.isBuffer = function (o) { return !!(o && o._u instanceof Uint8Array); };
    Buf.byteLength = function (v, enc) { return toU8(v, enc).length; };
    Buf.concat = function (arr, total) {
      var n = total || 0;
      if (!n) { for (var i = 0; i < arr.length; i++) n += arr[i].length; }
      var u = new Uint8Array(n), p = 0;
      for (var j = 0; j < arr.length; j++) {
        var src = arr[j]._u || new Uint8Array(arr[j]);
        u.set(src, p);
        p += src.length;
      }
      return Buf(u);
    };
    return { Buffer: Buf, __esModule: true, default: { Buffer: Buf } };
  }

  /* ---------------- require 白名单 ---------------- */
  function buildPackages(lx, log) {
    var CryptoJS = global.CryptoJS || {};
    var notSupported = function (name) {
      return new Proxy(function () {}, {
        get: function () {
          return function () {
            throw new Error('此 MusicFree 插件依赖 ' + name + '，音栈当前不提供该能力');
          };
        },
        apply: function () {
          throw new Error('此 MusicFree 插件依赖 ' + name + '，音栈当前不提供该能力');
        }
      });
    };
    return {
      'axios': makeAxios(lx, log),
      'crypto-js': CryptoJS,
      'cheerio': cheerio,
      'dayjs': dayjs,
      'he': { decode: decodeEntities, encode: encodeEntities },
      'qs': { stringify: qsStringify, parse: qsParse },
      'big-integer': bigInt,
      // v2.42：社区订阅（cwo.cc.cd / 全豆要 / 磁带带等）插件顶层硬依赖 require('buffer')，
      // 给一份真 Buffer 实现；不返回假对象，避免这些插件在 require 阶段就崩。
      'buffer': makeBuffer(),
      // pako 是 DEFLATE 压缩库，ArkWeb 无原生实现；这些插件只在取链 / 解压响应时用。
      // 用 notSupported 让具名方法照常导出、搜索页能识别，真正用到时明确抛错，
      // 不伪装成可用（与 webdav 同策略）。
      'pako': notSupported('pako（DEFLATE 压缩）'),
      // crypto 故意不加白名单：这些插件用 `try { require('crypto') } catch { 降级 crypto-js }`，
      // 让 require 抛错走 catch 反而能正确降级到已注入的 crypto-js，
      // 若塞个假对象会让 try 成功、后续调用才崩，体验更差。
      // WebDAV / 原生 cookie 管理器需要用户自己的服务器与 RN 原生模块，
      // 这类插件（webdav / navidrome / airsonic）在本环境无法真实运行，
      // 明确抛错而不是伪装成可用。
      'webdav': notSupported('webdav（网盘客户端）'),
      '@react-native-cookies/cookies': { get: function () { return Promise.resolve({}); }, set: function () {}, flush: function () {} }
    };
  }

  /* ---------------- 协议翻译：洛雪 action → MusicFree 方法 ----------------
   * MusicFree 官方只有 low / standard / high / super 四档，音栈有 9 档。
   * 高规格档（master / atmos_plus / atmos / hires / flac24bit / flac）一律
   * 按最高档 super 索取 —— 老实现只认 flac/hires/sq/lossless，用户选「母带」
   * 或「全景声」时会被映射成最低的 standard，插件给个有损链接也当成达标，
   * 等于偷偷降质。宁可向插件要 super 让它如实失败，也不要替用户降档。
   */
  function qualityOf(raw) {
    var q = String(raw || '').toLowerCase();
    if (q.indexOf('master') >= 0 || q.indexOf('atmos') >= 0 ||
        q.indexOf('hires') >= 0 || q.indexOf('hi-res') >= 0 ||
        q.indexOf('flac') >= 0 || q.indexOf('24bit') >= 0 ||
        q.indexOf('sq') >= 0 || q.indexOf('lossless') >= 0) return 'super';
    if (q.indexOf('320') >= 0) return 'high';
    if (q.indexOf('128') >= 0) return 'low';
    return 'standard'; // 192k 及未知档
  }

  /** 从洛雪 musicInfo 还原 MusicFree 的原始 mediaItem（含插件自定义字段） */
  function restoreMedia(info) {
    var mi = (info && info.musicInfo) || {};
    if (mi.mfRaw) {
      try { return JSON.parse(mi.mfRaw); } catch (e) { /* 落到下面的兜底 */ }
    }
    return {
      id: mi.id || '',
      title: mi.name || '',
      artist: mi.singer || '',
      album: mi.albumName || mi.album || '',
      artwork: mi.cover || '',
      duration: mi.duration || 0,
      platform: mi.source || ''
    };
  }

  /** MusicFree mediaItem → 音栈 SongInfo（保留原始对象以便取链时回传） */
  function toSong(it, sourceId) {
    var obj = it || {};
    var id = obj.id === undefined || obj.id === null ? '' : String(obj.id);
    return {
      id: id,
      songmid: id,
      hash: '',
      name: String(obj.title || ''),
      singer: String(obj.artist || ''),
      album: String(obj.album || ''),
      albumName: String(obj.album || ''),
      interval: '',
      source: sourceId,
      duration: Number(obj.duration || 0),
      cover: String(obj.artwork || ''),
      lyric: '',
      url: '',
      quality: '',
      // 关键：把插件自己的对象原样带走，getMediaSource / getLyric 才能认出这首歌
      mfRaw: JSON.stringify(obj)
    };
  }

  function makeRequest(plugin, sourceId, log) {
    // 插件内部抛错一律收敛成「不处理」，不能冒到 __emit 把整轮取链 / 搜索打断。
    // 洛雪协议里返回 {} 表示「这个音源处理不了」，由宿主继续尝试其它音源。
    // 取链（musicUrl）例外：异常要作为真实失败原因回传给宿主。桥接页会把
    // rejected 的任务记进 firstError，失败面板就能显示插件到底为什么崩；
    // 否则一律变成 {}，只显示兜底文案「音源未返回有效链接」。
    function guard(promise, empty, exposeError) {
      return Promise.resolve(promise).catch(function (err) {
        var msg = String((err && err.message) || err);
        log('[MF] ' + msg);
        if (exposeError) {
          return Promise.reject(new Error('插件取链异常：' + msg));
        }
        return empty;
      });
    }

    /* ---------------- v2.44：歌单 / 歌手搜索与详情 ---------------- */
    /**
     * 官方协议 search(query, page, type) 的 type ∈ music|album|artist|sheet|lyric。
     * 插件声明 supportedSearchType 时只认声明过的类型；没声明就让它自己返回空，
     * 绝不由宿主伪造歌单 / 歌手结果。
     */
    function supportsSearchType(type) {
      var sst = plugin.supportedSearchType;
      return !(Array.isArray(sst) && sst.indexOf(type) < 0);
    }
    /** 详情页回传：还原插件自己的 sheetItem / artistItem（含自定义字段） */
    function restoreItem(raw) {
      if (typeof raw === 'string' && raw.length > 0) {
        try { return JSON.parse(raw); } catch (e) { /* 落到兜底 */ }
      }
      return (raw && typeof raw === 'object') ? raw : {};
    }
    /** IMusicSheetItem → 音栈 SheetInfo（mfRaw 原样带走，供 getMusicSheetInfo） */
    function toSheet(it, sid) {
      var o = it || {};
      return {
        id: String(o.id === undefined || o.id === null ? '' : o.id),
        name: String(o.title || o.name || ''),
        cover: String(o.artwork || o.cover || o.coverImgUrl || o.pic || ''),
        description: String(o.description || o.desc || ''),
        platform: sid,
        kind: 'playlist',
        trackCount: Number(o.musicNum || o.worksNum || o.trackCount || o.songCount || 0),
        playCount: Number(o.playCount || o.listenNum || 0),
        creator: String(o.artist || o.creator || o.userName || o.nickname || ''),
        updateTime: String(o.updateTime || ''),
        subtitle: '',
        mfRaw: JSON.stringify(o)
      };
    }
    /** IArtistItem → 音栈 ArtistInfo（mfRaw 原样带走，供 getArtistWorks） */
    function toArtist(it, sid) {
      var o = it || {};
      return {
        id: String(o.id === undefined || o.id === null ? '' : o.id),
        name: String(o.name || o.title || ''),
        avatar: String(o.avatar || o.artwork || o.cover || o.pic || ''),
        platform: sid,
        subtitle: String(o.alias || o.description || ''),
        mfRaw: JSON.stringify(o)
      };
    }
    return function (action, args) {
      var info = (args && args.info) || {};
      if (action === 'musicSearch') {
        if (typeof plugin.search !== 'function') return Promise.resolve({ data: [], isEnd: true });
        var searchCall;
        try { searchCall = plugin.search(info.keyword || '', info.page || 1, 'music'); }
        catch (e) { return guard(Promise.reject(e), { data: [], isEnd: true }); }
        return guard(Promise.resolve(searchCall).then(function (res) {
          var list = (res && res.data) || [];
          return {
            data: list.map(function (it) { return toSong(it, sourceId); }),
            isEnd: res ? res.isEnd !== false : true
          };
        }), { data: [], isEnd: true });
      }
      if (action === 'musicUrl') {
        if (typeof plugin.getMediaSource !== 'function') return Promise.resolve({});
        var media = restoreMedia(info);
        // 插件缺失字段时补上，避免它拿到 undefined
        if (!media.platform) media.platform = sourceId;
        var mediaCall;
        try { mediaCall = plugin.getMediaSource(media, qualityOf(info.quality || info.type)); }
        catch (e) { return guard(Promise.reject(e), {}, true); }
        return guard(Promise.resolve(mediaCall).then(function (res) {
          // 插件正常返回但没给链接，仍按「不处理」处理；只有抛错才算真实失败原因。
          if (!res || !res.url) return {};
          var headers = {};
          if (res.headers) Object.keys(res.headers).forEach(function (k) { headers[k] = res.headers[k]; });
          if (res.userAgent && !headers['User-Agent'] && !headers['user-agent']) {
            headers['User-Agent'] = res.userAgent;
          }
          return { url: res.url, headers: headers };
        }), {}, true);
      }
      if (action === 'lyric') {
        if (typeof plugin.getLyric !== 'function') return Promise.resolve({});
        var m = restoreMedia(info);
        var lyricCall;
        try { lyricCall = plugin.getLyric(m); }
        catch (e) { return guard(Promise.reject(e), {}); }
        return guard(Promise.resolve(lyricCall).then(function (res) {
          if (!res || !res.rawLrc) return {};
          // 对齐洛雪 lyric 返回结构（LyricRepo.toDoc 会取 lyric / tlyric）
          return { lyric: res.rawLrc, tlyric: res.translation || '' };
        }), {});
      }
      /* ---- 歌单搜索：官方 search(type='sheet') ---- */
      if (action === 'sheetSearch') {
        if (typeof plugin.search !== 'function' || !supportsSearchType('sheet')) {
          return Promise.resolve({ data: [], isEnd: true });
        }
        var sheetCall;
        try { sheetCall = plugin.search(info.keyword || '', info.page || 1, 'sheet'); }
        catch (e) { return guard(Promise.reject(e), { data: [], isEnd: true }); }
        return guard(Promise.resolve(sheetCall).then(function (res) {
          var list = (res && (res.data || res.sheets)) || [];
          return {
            data: list.map(function (it) { return toSheet(it, sourceId); }),
            isEnd: res ? res.isEnd !== false : true
          };
        }), { data: [], isEnd: true });
      }
      /* ---- 歌手搜索：官方 search(type='artist') ---- */
      if (action === 'artistSearch') {
        if (typeof plugin.search !== 'function' || !supportsSearchType('artist')) {
          return Promise.resolve({ data: [], isEnd: true });
        }
        var artistCall;
        try { artistCall = plugin.search(info.keyword || '', info.page || 1, 'artist'); }
        catch (e) { return guard(Promise.reject(e), { data: [], isEnd: true }); }
        return guard(Promise.resolve(artistCall).then(function (res) {
          var list = (res && (res.data || res.artists)) || [];
          return {
            data: list.map(function (it) { return toArtist(it, sourceId); }),
            isEnd: res ? res.isEnd !== false : true
          };
        }), { data: [], isEnd: true });
      }
      /* ---- 歌单详情：官方 getMusicSheetInfo(sheetItem, page) ---- */
      if (action === 'sheetInfo') {
        if (typeof plugin.getMusicSheetInfo !== 'function') return Promise.resolve({ data: [], isEnd: true });
        var sheetInfoCall;
        try { sheetInfoCall = plugin.getMusicSheetInfo(restoreItem(info.mfRaw), info.page || 1); }
        catch (e) { return guard(Promise.reject(e), { data: [], isEnd: true }); }
        return guard(Promise.resolve(sheetInfoCall).then(function (res) {
          var list = (res && (res.musicList || res.data || res.songs)) || [];
          return {
            data: list.map(function (it) { return toSong(it, sourceId); }),
            isEnd: res ? res.isEnd !== false : true
          };
        }), { data: [], isEnd: true });
      }
      /* ---- 歌手作品：官方 getArtistWorks(artistItem, page, 'music') ---- */
      if (action === 'artistWorks') {
        if (typeof plugin.getArtistWorks !== 'function') return Promise.resolve({ data: [], isEnd: true });
        var worksCall;
        try { worksCall = plugin.getArtistWorks(restoreItem(info.mfRaw), info.page || 1, 'music'); }
        catch (e) { return guard(Promise.reject(e), { data: [], isEnd: true }); }
        return guard(Promise.resolve(worksCall).then(function (res) {
          var list = (res && (res.data || res.musicList || res.songs)) || [];
          return {
            data: list.map(function (it) { return toSong(it, sourceId); }),
            isEnd: res ? res.isEnd !== false : true
          };
        }), { data: [], isEnd: true });
      }
      return Promise.resolve({});
    };
  }

  /* ---------------- ESM → CommonJS 预处理 ---------------- */
  /**
   * 官方 dist 是 TS 编译出的 CommonJS，但社区里大量插件是 ESM 或手写
   * `export default {...}`。Function() 装载器只认 CommonJS，这里做最小
   * 必要的降级，避免这类插件在语法阶段就崩掉。
   * 不做完整 TypeScript 转译：带类型注解的 .ts 源码仍应使用官方 dist。
   */
  function toCommonJS(code) {
    var text = String(code || '');
    // import axios from 'axios' —— 官方 _require 会把模块挂 .default，这里兼容两种
    text = text.replace(/^\s*import\s+([A-Za-z_$][\w$]*)\s+from\s+(['"])([^'"]+)\2\s*;?/gm,
      'var $1 = require($2$3$2); if ($1 && $1.default) $1 = $1.default;');
    text = text.replace(/^\s*import\s+\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+(['"])([^'"]+)\2\s*;?/gm,
      'var $1 = require($2$3$2);');
    text = text.replace(/^\s*import\s*\{([^}]+)\}\s*from\s+(['"])([^'"]+)\2\s*;?/gm,
      function (_m, names, q, mod) {
        var parts = [];
        var arr = names.split(',');
        for (var i = 0; i < arr.length; i++) {
          var t = arr[i].trim();
          if (!t) continue;
          var as = /^([\w$]+)\s+as\s+([\w$]+)$/.exec(t);
          parts.push(as ? as[1] + ': ' + as[2] : t);
        }
        return 'var { ' + parts.join(', ') + ' } = require(' + q + mod + q + ') || {};';
      });
    text = text.replace(/^\s*import\s+(['"])([^'"]+)\1\s*;?/gm, 'require($1$2$1);');
    // export default <expr> → module.exports = <expr>
    text = text.replace(/^\s*export\s+default\s+/m, 'module.exports = ');
    text = text.replace(/^\s*export\s*\{\s*([\w$]+)\s+as\s+default\s*\}\s*;?/gm, 'module.exports = $1;');
    text = text.replace(/^\s*export\s+(?=(?:const|let|var|function|class|async)\b)/gm, '');
    text = text.replace(/^\s*export\s*\{[^}]*\}\s*;?/gm, '');
    text = text.replace(/^\s*export\s+\*\s+from\s+[^;]+;?/gm, '');
    return text;
  }

  /* ---------------- 插件内部异步异常兜底 ---------------- */
  /**
   * 部分插件（如官方 suno）在模块顶层就自调用一次异步方法，且没有 catch。
   * 网络异常时会产生 unhandledrejection；收敛成日志，别让它冒到 ArkWeb 宿主。
   */
  var rejectionHooked = false;
  function hookUnhandledRejection(log) {
    if (rejectionHooked) {
      return;
    }
    rejectionHooked = true;
    try {
      if (typeof global.addEventListener === 'function') {
        global.addEventListener('unhandledrejection', function (ev) {
          try {
            var reason = ev && ev.reason;
            log('[MF] 插件内部未处理的异步异常：' + String((reason && reason.message) || reason || ev));
          } catch (e) { /* 忽略 */ }
          try {
            if (ev && typeof ev.preventDefault === 'function') {
              ev.preventDefault();
            }
          } catch (e2) { /* 忽略 */ }
        });
      }
    } catch (e) { /* 沙箱不支持则忽略 */ }
  }

  /* ---------------- 装载 ---------------- */
  function load(instId, code, host) {
    var lx = host.lx;
    var log = host.log || function () {};
    hookUnhandledRejection(log);
    var packages = buildPackages(lx, log);
    var _module = { exports: {} };
    var _exports = _module.exports;
    var _require = function (name) {
      var pkg = packages[name];
      if (pkg === undefined) {
        throw new Error('MusicFree 插件引用了未提供的依赖：' + name);
      }
      // 官方 _require 会把模块本身挂到 .default；CommonJS/TS 编译产物常读 .default
      try { pkg.default = pkg; } catch (e) { /* 冻结对象忽略 */ }
      return pkg;
    };
    var env = {
      getUserVariables: function () { return {}; },
      appVersion: '1.0',
      os: 'android',
      lang: 'zh-CN'
    };
    var _process = { platform: 'android', version: '1.0', env: env };
    var _console = {
      log: function () { log('[log] ' + Array.prototype.slice.call(arguments).join(' ')); },
      warn: function () { log('[warn] ' + Array.prototype.slice.call(arguments).join(' ')); },
      info: function () { log('[info] ' + Array.prototype.slice.call(arguments).join(' ')); },
      error: function () { log('[error] ' + Array.prototype.slice.call(arguments).join(' ')); }
    };
    // 与官方 plugin.ts 完全同款：用 Function 包一层，把 CommonJS 环境作为形参注入，
    // 而不是把 module / exports 挂全局（后者会污染同页其它音源实例）。
    // 先做 ESM → CommonJS 降级；官方 dist 本来就是 CommonJS，原样通过。
    var normalized = toCommonJS(code);
    var factory = Function(
      '"use strict"; return function(require, __musicfree_require, module, exports, console, env, URL, process){' +
      normalized + '\n}'
    )();
    factory(_require, _require, _module, _exports, _console, env, global.URL, _process);
    // TS 编译产物、exports.default = {...}、export default 三条路径都能拿到插件对象
    var exported = _module.exports || _exports || {};
    var plugin = (exported.default && typeof exported.default === 'object') ? exported.default : exported;
    if (!plugin || typeof plugin !== 'object') {
      throw new Error('插件没有导出 module.exports 对象');
    }
    var platform = String(plugin.platform || '').trim();
    if (platform.length === 0 || platform === '本地') {
      throw new Error('插件缺少合法的 platform 字段');
    }
    var sourceId = 'mf:' + instId;
    var actions = ['musicUrl'];
    if (typeof plugin.getLyric === 'function') actions.push('lyric');
    if (typeof plugin.search === 'function') actions.push('musicSearch');
    return {
      name: platform,
      platform: platform,
      version: String(plugin.version || '0.0.0'),
      srcUrl: String(plugin.srcUrl || ''),
      author: String(plugin.author || ''),
      sourceId: sourceId,
      actions: actions,
      hasSearch: typeof plugin.search === 'function',
      hasMedia: typeof plugin.getMediaSource === 'function',
      hasLyric: typeof plugin.getLyric === 'function',
      request: makeRequest(plugin, sourceId, log)
    };
  }

  global.MFRuntime = { load: load, qualityOf: qualityOf, toSong: toSong };
})(window);
