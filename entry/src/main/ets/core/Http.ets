import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

export const UA_MOBILE: string =
  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

export interface HttpResult {
  ok: boolean;
  status: number;
  body: string;
  error: string;
  headers: Record<string, string>;
}

export interface HttpOptions {
  method: string;
  headers: Record<string, string>;
  body: string;
  timeout: number;
  referer: string;
}

/**
 * 状态码翻成人话。
 * 以前非 2xx 一律拼成 "HTTP 404"，播放失败时这条会原样弹给用户，
 * 看不出是「接口没了」还是「被拒绝」还是「网络问题」。
 */
export function httpStatusText(code: number): string {
  if (code === 401 || code === 403) {
    return '接口拒绝访问（' + code.toString() + '）';
  }
  if (code === 404) {
    return '接口已失效（404）';
  }
  if (code === 429) {
    return '请求过于频繁（429）';
  }
  if (code >= 500) {
    return '服务器出错（' + code.toString() + '）';
  }
  return 'HTTP ' + code.toString();
}

export function httpOptions(): HttpOptions {
  return { method: 'GET', headers: {}, body: '', timeout: 15000, referer: '' };
}

/** 底层请求，所有网络层共用 */
export function request(url: string, options: HttpOptions): Promise<HttpResult> {
  const client = http.createHttp();
  const headers: Record<string, string> = { 'User-Agent': UA };
  if (options.referer.length > 0) {
    headers['Referer'] = options.referer;
  }
  const keys = Object.keys(options.headers);
  for (const key of keys) {
    headers[key] = options.headers[key];
  }
  const method = options.method.toUpperCase();
  const reqOptions: http.HttpRequestOptions = {
    method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
    header: headers,
    extraData: options.body,
    expectDataType: http.HttpDataType.STRING,
    usingCache: false,
    connectTimeout: Math.min(options.timeout, 20000),
    readTimeout: options.timeout
  };
  return new Promise<HttpResult>((resolve) => {
    // client.request 对空/非法 URL 会同步抛。没有这层保护时 Promise 永不 resolve，
    // 上层 await 会一直挂着，表现为「点了播放一直转圈到 30 秒总超时」。
    try {
      client.request(url, reqOptions, (err: BusinessError, data: http.HttpResponse) => {
        const result: HttpResult = { ok: false, status: 0, body: '', error: '', headers: {} };
        if (err) {
          result.error = err.message ?? '网络请求失败';
        } else {
          result.status = data.responseCode;
          // 只认 2xx：3xx 多为「接口已下线」的跳转页（如咪咕 v3 歌词接口 301 到首页），
          // 把这种 HTML 当成响应体交给上层，会被当成歌词/JSON 直接显示出来。
          result.ok = data.responseCode >= 200 && data.responseCode < 300;
          result.body = typeof data.result === 'string' ? data.result : String(data.result ?? '');
          const header = data.header as Record<string, Object>;
          const headerKeys = Object.keys(header);
          for (const key of headerKeys) {
            const value = header[key];
            result.headers[key.toLowerCase()] = typeof value === 'string' ? value : String(value);
          }
          if (!result.ok) {
            result.error = httpStatusText(data.responseCode);
          }
        }
        client.destroy();
        resolve(result);
      });
    } catch (e) {
      const failed: HttpResult = { ok: false, status: 0, body: '', error: '请求地址无效', headers: {} };
      try {
        client.destroy();
      } catch (err) {
        // 已销毁
      }
      resolve(failed);
    }
  });
}

export async function getText(url: string, referer: string = '', timeout: number = 15000): Promise<string> {
  const options = httpOptions();
  options.referer = referer;
  options.timeout = timeout;
  const result = await request(url, options);
  if (!result.ok) {
    throw new Error(result.error.length > 0 ? result.error : '请求失败');
  }
  return result.body;
}

export async function getJson<T>(url: string, referer: string = '', timeout: number = 15000): Promise<T> {
  const text = await getText(url, referer, timeout);
  return JSON.parse(text) as T;
}

/**
 * 带自定义请求头的 GET。
 * 个别平台（网易云）对未带 Cookie 的请求做降级：歌单详情只回前 10 首曲目，
 * 补一个固定的 os/appver Cookie 就能拿全量，这里给调用方留出口子。
 */
export async function getTextWith(url: string, referer: string, headers: Record<string, string>,
  timeout: number = 15000): Promise<string> {
  const options = httpOptions();
  options.referer = referer;
  options.timeout = timeout;
  const keys = Object.keys(headers);
  for (const key of keys) {
    options.headers[key] = headers[key];
  }
  const result = await request(url, options);
  if (!result.ok) {
    throw new Error(result.error.length > 0 ? result.error : '请求失败');
  }
  return result.body;
}

export async function getJsonWith<T>(url: string, referer: string, headers: Record<string, string>,
  timeout: number = 15000): Promise<T> {
  const text = await getTextWith(url, referer, headers, timeout);
  return JSON.parse(text) as T;
}

export async function postForm(url: string, body: string, referer: string = '',
  timeout: number = 15000): Promise<string> {
  const options = httpOptions();
  options.method = 'POST';
  options.body = body;
  options.referer = referer;
  options.timeout = timeout;
  options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
  const result = await request(url, options);
  if (!result.ok) {
    throw new Error(result.error.length > 0 ? result.error : '请求失败');
  }
  return result.body;
}

/** 探测音频总体积：优先 Content-Range，其次 Content-Length；拿不到返回 0 */
export async function audioTotalSize(url: string): Promise<number> {
  const options = httpOptions();
  options.headers['Range'] = 'bytes=0-0';
  options.headers['User-Agent'] = 'okhttp/4.10.0';
  options.timeout = 6000;
  const result = await request(url, options);
  if (!result.ok && result.status !== 206) {
    return 0;
  }
  const range = result.headers['content-range'];
  if (range !== undefined) {
    const slash = range.lastIndexOf('/');
    if (slash >= 0) {
      const total = Number.parseInt(range.substring(slash + 1));
      if (!Number.isNaN(total)) {
        return total;
      }
    }
  }
  const length = result.headers['content-length'];
  if (length !== undefined) {
    const total = Number.parseInt(length);
    if (!Number.isNaN(total)) {
      return total;
    }
  }
  return 0;
}

export interface ProbeResult {
  ok: boolean;
  /** 跟随跳转之后的真实地址（播放器要用这个） */
  url: string;
  type: string;
  size: number;
  /** 真实格式：flac / mp3 / m4a / ogg / wav / unknown */
  format: string;
  /** 按 体积 ÷ 时长 估出来的码率（kbps），0 表示无法判断 */
  kbps: number;
  reason: string;
}

/**
 * 判断真实音频格式。
 *
 * 只信 Content-Type 会吃亏：大量中转接口统一回 application/octet-stream，
 * 而它们恰恰是最容易「说无损给 128k」的一类。所以 Content-Type 认不出来时
 * 再看地址后缀，最后才用体积估的码率兜底。
 */
export function detectFormat(type: string, url: string, size: number, durationSec: number): string {
  const t = type.toLowerCase();
  /**
   * 码率仲裁（v2.56 无损判定修复）。
   *
   * 有损容器有物理上限：MP3 ≤320kbps、AAC/M4A 极少 >400kbps、Ogg Vorbis 一般
   * <500kbps。实测码率 ≥640kbps 时，文件只可能是 FLAC / APE / WAV 这类无损。
   * 但中转 / 聚合接口为了兼容老播放器，常把无损链接统一回
   * `Content-Type: audio/mpeg`，或把 URL 后缀写成 .mp3 —— 旧版第 224 行一见
   * mpeg/mp3 就提前 return 'mp3'，压根走不到函数末尾的「码率 ≥500 判 flac」兜底。
   * 结果就是「25 个音源齐刷刷报 FLAC：只给到320K（mp3 969kbps）」：音源其实
   * 全给了真无损，却被达标门禁当成有损逐个拒绝，选 FLAC 必定全军覆没。
   *
   * 物理证据优先于标签：码率够高就以码率为准；标签只在低码率时才可信，
   * 这样真 128k / 320k 的 mp3 仍会被判有损，「绝不降质」不被破坏。
   */
  const kbps = size > 0 && durationSec > 0 ? size * 8 / durationSec / 1000 : 0;
  if (kbps >= 640) {
    return 'flac';
  }
  if (t.indexOf('flac') >= 0) {
    return 'flac';
  }
  if (t.indexOf('mpeg') >= 0 || t.indexOf('mp3') >= 0) {
    return 'mp3';
  }
  if (t.indexOf('mp4') >= 0 || t.indexOf('m4a') >= 0 || t.indexOf('aac') >= 0) {
    return 'm4a';
  }
  if (t.indexOf('ogg') >= 0 || t.indexOf('opus') >= 0) {
    return 'ogg';
  }
  if (t.indexOf('wav') >= 0) {
    return 'wav';
  }
  const u = url.toLowerCase();
  const cut = u.indexOf('?');
  const path = cut >= 0 ? u.substring(0, cut) : u;
  if (path.endsWith('.flac')) {
    return 'flac';
  }
  if (path.endsWith('.mp3')) {
    return 'mp3';
  }
  if (path.endsWith('.m4a') || path.endsWith('.mp4') || path.endsWith('.aac')) {
    return 'm4a';
  }
  if (path.endsWith('.ogg') || path.endsWith('.opus')) {
    return 'ogg';
  }
  if (path.endsWith('.wav')) {
    return 'wav';
  }
  // 中转 / 聚合 API 把真实格式放在查询参数里而不是后缀：
  //   /api.php?type=flac&level=hires、?quality=lossless、?br=999（24bit）
  // 先排除明确的有损线索，再认无损线索，免得把 mp3 误判成 flac。
  const query = cut >= 0 ? u.substring(cut + 1) : '';
  if (query.indexOf('type=mp3') >= 0 || query.indexOf('level=mp3') >= 0 ||
    query.indexOf('quality=128') >= 0 || query.indexOf('br=128') >= 0) {
    return 'mp3';
  }
  if (query.indexOf('flac') >= 0 || query.indexOf('lossless') >= 0 ||
    query.indexOf('hires') >= 0 || query.indexOf('24bit') >= 0 ||
    query.indexOf('master') >= 0 || query.indexOf('atmos') >= 0 ||
    query.indexOf('br=999') >= 0) {
    return 'flac';
  }
  // 什么都认不出来时，用码率给一个保守猜测：只有明显超过 500kbps 才敢认为是无损
  if (kbps > 0) {
    if (kbps >= 500) {
      return 'flac';
    }
    if (kbps >= 160) {
      return 'mp3';
    }
  }
  return 'unknown';
}

/** 把 Location 解析成绝对地址（很多音源返回 http → https 的 301） */
export function absoluteUrl(base: string, location: string): string {
  if (location.startsWith('http://') || location.startsWith('https://')) {
    return location;
  }
  if (location.startsWith('//')) {
    return 'https:' + location;
  }
  const schemeEnd = base.indexOf('://');
  if (schemeEnd < 0) {
    return location;
  }
  const pathStart = base.indexOf('/', schemeEnd + 3);
  const origin = pathStart < 0 ? base : base.substring(0, pathStart);
  if (location.startsWith('/')) {
    return origin + location;
  }
  const dir = pathStart < 0 ? origin + '/' : base.substring(0, base.lastIndexOf('/') + 1);
  return dir + location;
}

/**
 * 链接是否可播放：一次 Range 请求同时看状态、类型和总体积。
 *
 * 必须跟随 301/302：大量音源（尤其是中转接口）返回的是 http 跳 https，
 * 不跟随会拿到一段 162 字节的 html，被误判成「不可用」。
 * 小于 400KB 且远小于按码率估算的整首体积，视作试听片段。
 */
/**
 * 探测音频真实格式与体积。
 *
 * extraHeaders 是音源随链接一起返回的防盗链头（Referer / Cookie /
 * User-Agent / X-Request-Key 等）。中转 / 聚合 API 几乎都靠它鉴权，
 * 不带就直接回 403 或一段 HTML，探测先挂、根本走不到下载。
 * 下载请求本来就带这些头，探测请求必须同样带上。
 */
export async function probeAudioEx(url: string, durationSec: number = 0,
  extraHeaders: Record<string, string> = {}): Promise<ProbeResult> {
  const out: ProbeResult = { ok: false, url: url, type: '', size: 0, format: 'unknown', kbps: 0, reason: '' };
  if (!url.startsWith('http')) {
    out.reason = '不是网络地址';
    return out;
  }
  let target = url;
  for (let hop = 0; hop < 4; hop++) {
    const options = httpOptions();
    const keys = Object.keys(extraHeaders);
    for (const key of keys) {
      options.headers[key] = extraHeaders[key];
    }
    options.headers['Range'] = 'bytes=0-0';
    if (options.headers['User-Agent'] === undefined && options.headers['user-agent'] === undefined) {
      options.headers['User-Agent'] = 'okhttp/4.10.0';
    }
    options.timeout = 6000;
    const result = await request(target, options);
    if (result.status >= 300 && result.status < 400) {
      const location = result.headers['location'] ?? '';
      if (location.length === 0) {
        out.reason = '跳转无地址';
        return out;
      }
      target = absoluteUrl(target, location);
      continue;
    }
    out.url = target;
    if (result.status !== 200 && result.status !== 206) {
      out.reason = 'HTTP ' + result.status.toString();
      return out;
    }
    const type = result.headers['content-type'] ?? '';
    out.type = type;
    if (type.indexOf('text/html') >= 0 || type.indexOf('application/json') >= 0) {
      out.reason = '返回的不是音频';
      return out;
    }
    let total = 0;
    const range = result.headers['content-range'];
    if (range !== undefined) {
      const slash = range.lastIndexOf('/');
      if (slash >= 0) {
        const parsed = Number.parseInt(range.substring(slash + 1));
        if (!Number.isNaN(parsed) && parsed > 0) {
          total = parsed;
        }
      }
    }
    if (total === 0) {
      // 有些服务器不认 Range，直接 200 回整首，这时 content-length 就是总长
      const length = result.headers['content-length'];
      if (length !== undefined) {
        const parsed = Number.parseInt(length);
        if (!Number.isNaN(parsed) && parsed > 0) {
          total = parsed;
        }
      }
    }
    if (total > 0) {
      out.size = total;
      out.kbps = durationSec > 0 ? Math.round(total * 8 / durationSec / 1000) : 0;
      const expect = durationSec > 0 ? durationSec * 12000 : 600 * 1024;
      const min = Math.max(400 * 1024, expect);
      if (total < min) {
        out.reason = '只有 ' + Math.round(total / 1024).toString() + 'KB，是试听片段';
        return out;
      }
    }
    out.format = detectFormat(type, target, out.size, durationSec);
    out.ok = true;
    return out;
  }
  out.reason = '跳转次数过多';
  return out;
}

export async function probeAudio(url: string, durationSec: number = 0): Promise<boolean> {
  const result = await probeAudioEx(url, durationSec);
  return result.ok;
}
