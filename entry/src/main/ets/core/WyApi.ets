import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import util from '@ohos.util';
import { request, httpOptions } from './Http';

/**
 * 网易云 Web 端 weapi 协议的本地实现（供「账号登录 / 个性化推荐」使用）。
 *
 * v2.64 新增。为什么这样设计：
 *  - 网易云 Web/PC 端把请求体用「双重 AES-128-CBC」加密成 params，再用 RSA 把
 *    第二把 AES 密钥封成 encSecKey。第三方客户端（NeteaseCloudMusicApi 等）都是这套。
 *  - 我们固定第二把密钥 SECRET_KEY，于是 encSecKey 变成**预计算的常量**（见下），
 *    运行时只需两次 AES-CBC，不需要 RSA 库、不需要 BigInt，ArkTS 原生即可完成。
 *  - 服务端用私钥解开 encSecKey 拿到 SECRET_KEY，再解开 params，与随机密钥等价。
 *    固定密钥不降低账号安全性：真正的凭证是 Cookie 里的 MUSIC_U，与它无关。
 *  - 已在沙箱端到端验证：本算法生成的请求可正常拿到 unikey / 扫码状态 / 推荐数据。
 *
 * 边界：只用于本人账号的登录与推荐读取，不做任何刷量、破解付费或批量请求。
 */

const PRESET_KEY: string = '0CoJUm6Qyw8W8jud';
const IV_TEXT: string = '0102030405060708';
const SECRET_KEY: string = 'yinzhan2026yinzh';
/** encSecKey = RSA_NoPadding(reverse(SECRET_KEY))，模幂预算，256 位十六进制 */
const ENC_SEC_KEY: string =
  '1574725733e9296dfe75a2fec38ef4ddf534adfda0e05f21ec1e8362323ab27fbb51f413d211bdfcf9503cdf45080a286e57b88a640615e15f5e8bad59547e9ae469f047453f8029ac55dbf2579fa0546a764170d3cae697aa29e972fa2d489fffa6ff1aa42b3c72bd8df90f62b5b9cacd94f2543076a7250d07a5f623a4153f';

export const WY_BASE: string = 'https://music.163.com';
export const WY_REFERER: string = 'https://music.163.com/';

export interface WyReply {
  ok: boolean;
  body: string;
  /** 响应头里的 set-cookie（扫码 803 时凭证在这里） */
  setCookie: string;
  error: string;
}

function toBytes(text: string): Uint8Array {
  const encoder = util.TextEncoder.create('utf-8');
  return encoder.encodeInto(text);
}

/** 单轮 AES-128-CBC(PKCS7) → base64，与官方 Web 端字节一致；失败返回空串由上层降级 */
function aesCbcBase64(plain: string, key: string): string {
  try {
    const keyBlob: cryptoFramework.DataBlob = { data: toBytes(key) };
    const symKey = cryptoFramework.createSymKeyGenerator('AES128').convertKeySync(keyBlob);
    const ivParams: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: toBytes(IV_TEXT) }
    };
    const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivParams);
    const out = cipher.doFinalSync({ data: toBytes(plain) });
    return new util.Base64Helper().encodeToStringSync(out.data);
  } catch (e) {
    // 少数设备缺 cryptoFramework syscap：给明确失败而不是让二维码页崩溃
    return '';
  }
}

/** 封面 URL 规整：与 PlatformApi 的私有 fixCover 等价（去 {size} 占位、http→https） */
export function wyFixCover(url: string): string {
  const value = (url ?? '').trim();
  if (value.length === 0) {
    return '';
  }
  if (value.startsWith('//')) {
    return 'https:' + value;
  }
  if (value.startsWith('http://')) {
    return 'https://' + value.substring(7);
  }
  return value.split('{size}').join('240');
}

/** 把明文参数对象封成 weapi 表单体：params=...&encSecKey=...；加密失败返回空串 */
export function weapiBody(data: Record<string, Object>): string {
  const text = JSON.stringify(data);
  const first = aesCbcBase64(text, PRESET_KEY);
  if (first.length === 0) {
    return '';
  }
  const params = aesCbcBase64(first, SECRET_KEY);
  if (params.length === 0) {
    return '';
  }
  return 'params=' + encodeURIComponent(params) + '&encSecKey=' + ENC_SEC_KEY;
}

/** 从 cookie 串里取某个键的值（不引正则，避免 ArkTS 匹配结果的类型坑） */
export function cookieValue(cookie: string, key: string): string {
  const needle = key + '=';
  const i = cookie.indexOf(needle);
  if (i < 0) {
    return '';
  }
  const start = i + needle.length;
  let end = cookie.length;
  const stops = [';', ',', ' '];
  for (const c of stops) {
    const p = cookie.indexOf(c, start);
    if (p >= 0 && p < end) {
      end = p;
    }
  }
  return cookie.substring(start, end);
}

/** 从扫码 803 / 用户粘贴的原始串里归一出可持久化的 Cookie */
export function normalizeCookie(raw: string): string {
  const musicU = cookieValue(raw, 'MUSIC_U');
  if (musicU.length === 0) {
    return '';
  }
  const csrf = cookieValue(raw, '__csrf');
  const musicA = cookieValue(raw, 'MUSIC_A');
  let out = 'MUSIC_U=' + musicU;
  if (csrf.length > 0) {
    out += '; __csrf=' + csrf;
  }
  if (musicA.length > 0) {
    out += '; MUSIC_A=' + musicA;
  }
  out += '; os=pc; appver=2.10.13; channel=netease; osver=Microsoft-Windows-10-Professional-build-19045-64bit';
  return out;
}

/**
 * 发一个 weapi POST。cookie 为空时按匿名游客发（用于取二维码 / 查登录态）。
 * 自动补齐 csrf_token（URL、请求体、Cookie 三处一致）。
 */
export async function wyPost(path: string, data: Record<string, Object>, cookie: string): Promise<WyReply> {
  const csrf = cookieValue(cookie, '__csrf');
  const payload: Record<string, Object> = {};
  const keys = Object.keys(data);
  for (const k of keys) {
    payload[k] = data[k];
  }
  payload['csrf_token'] = csrf;

  const bodyText = weapiBody(payload);
  if (bodyText.length === 0) {
    return { ok: false, body: '', setCookie: '', error: '本机加密能力不可用' };
  }
  const options = httpOptions();
  options.method = 'POST';
  options.body = bodyText;
  options.referer = WY_REFERER;
  options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
  options.headers['Cookie'] = cookie.length > 0
    ? cookie
    : 'os=pc; appver=2.10.13; channel=netease; __csrf=';
  options.headers['User-Agent'] =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  const result = await request(WY_BASE + path + '?csrf_token=' + csrf, options);
  return {
    ok: result.ok,
    body: result.body,
    setCookie: result.headers['set-cookie'] ?? '',
    error: result.error
  };
}
