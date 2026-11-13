/**
 * 小工具集合：颜色、哈希、格式化、异步等待。
 * 不依赖任何页面，方便 core 层复用。
 */

/** 给 #RRGGBB / #AARRGGBB 叠加透明度，返回 rgba() */
export function withAlpha(color: string, alpha: number): string {
  let hex = color;
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  }
  if (hex.length === 8) {
    hex = hex.substring(2);
  }
  if (hex.length !== 6) {
    return 'rgba(120,120,120,' + alpha.toString() + ')';
  }
  const r = Number.parseInt(hex.substring(0, 2), 16);
  const g = Number.parseInt(hex.substring(2, 4), 16);
  const b = Number.parseInt(hex.substring(4, 6), 16);
  return 'rgba(' + r.toString() + ',' + g.toString() + ',' + b.toString() + ',' + alpha.toString() + ')';
}

/** 把颜色调亮/调暗，ratio > 0 变亮，< 0 变暗 */
export function shade(color: string, ratio: number): string {
  let hex = color;
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  }
  if (hex.length === 8) {
    hex = hex.substring(2);
  }
  if (hex.length !== 6) {
    return color;
  }
  const adjust = (value: number): number => {
    const target = ratio > 0 ? 255 : 0;
    const result = Math.round(value + (target - value) * Math.abs(ratio));
    return Math.max(0, Math.min(255, result));
  };
  const r = adjust(Number.parseInt(hex.substring(0, 2), 16));
  const g = adjust(Number.parseInt(hex.substring(2, 4), 16));
  const b = adjust(Number.parseInt(hex.substring(4, 6), 16));
  return '#' + toHex(r) + toHex(g) + toHex(b);
}

function toHex(value: number): string {
  const text = value.toString(16);
  return text.length === 1 ? '0' + text : text;
}

/** 无封面时按名字生成稳定的双色渐变，避免列表一片灰 */
export function seededGradient(seed: string): string[] {
  let hash = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    hash = hash ^ seed.charCodeAt(i);
    hash = (hash * 16777619) >>> 0;
  }
  const hue = hash % 360;
  const from = 'hsl(' + hue.toString() + ', 55%, 78%)';
  const to = 'hsl(' + ((hue + 42) % 360).toString() + ', 62%, 62%)';
  return [from, to];
}

/** HSL 单通道 → 两位十六进制 */
function hslChannel(value: number, m: number): string {
  const n: number = Math.round((value + m) * 255);
  const s: string = n.toString(16);
  return s.length < 2 ? '0' + s : s;
}

/** HSL → #RRGGBB。ArkUI 的 linearGradient 不解析 hsl() 字符串，必须给十六进制 */
function hslToHex(hue: number, sat: number, light: number): string {
  const h: number = ((hue % 360) + 360) % 360;
  const c: number = (1 - Math.abs(2 * light - 1)) * sat;
  const x: number = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m: number = light - c / 2;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (h < 60) {
    r = c;
    g = x;
  } else if (h < 120) {
    r = x;
    g = c;
  } else if (h < 180) {
    g = c;
    b = x;
  } else if (h < 240) {
    g = x;
    b = c;
  } else if (h < 300) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  return '#' + hslChannel(r, m) + hslChannel(g, m) + hslChannel(b, m);
}

/**
 * 占位色块专用渐变：给「没加载到图片」的封面/头像兜底。
 * 返回十六进制（hsl() 直接传给 linearGradient 在深色下整块不渲染，只剩一圈黑框），
 * 亮度压到中等，白色 ♪ / 歌手名首字占位文字才看得清。
 */
export function placeholderGradient(seed: string): string[] {
  let hash = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    hash = hash ^ seed.charCodeAt(i);
    hash = (hash * 16777619) >>> 0;
  }
  const hue: number = hash % 360;
  return [hslToHex(hue, 0.42, 0.50), hslToHex((hue + 42) % 360, 0.48, 0.34)];
}

/** 稳定 id（FNV-1a 双 32 位拼 base36） */
export function stableId(text: string): string {
  let h1 = 2166136261;
  let h2 = 5381;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    h1 = (h1 ^ code) >>> 0;
    h1 = Math.imul(h1, 16777619) >>> 0;
    h2 = ((h2 << 5) + h2 + code) >>> 0;
  }
  return h1.toString(36) + h2.toString(36);
}

export function uuid(): string {
  return Date.now().toString(36) + '-' + Math.floor(Math.random() * 1679616).toString(36);
}

export function clamp(value: number, min: number, max: number): number {
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

export function wait(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}

export function firstSinger(singer: string): string {
  const idx1 = singer.indexOf('/');
  const idx2 = singer.indexOf('&');
  let cut = singer.length;
  if (idx1 > 0) {
    cut = Math.min(cut, idx1);
  }
  if (idx2 > 0) {
    cut = Math.min(cut, idx2);
  }
  return singer.substring(0, cut).trim();
}

/** 从 URL 猜音频格式，用于播放页展示 FLAC / MP3 */
export function audioFormat(url: string): string {
  const lower = url.toLowerCase();
  if (lower.indexOf('.flac') >= 0) {
    return 'FLAC';
  }
  if (lower.indexOf('.m4a') >= 0 || lower.indexOf('.mp4') >= 0) {
    return 'M4A';
  }
  if (lower.indexOf('.ogg') >= 0) {
    return 'OGG';
  }
  if (lower.indexOf('.wav') >= 0) {
    return 'WAV';
  }
  return '';
}

/** 文件名安全化 */
export function safeFileName(name: string): string {
  return name.replace(/[\\/:*?"<>|]/g, '_').substring(0, 80);
}

/** 解析 set-cookie 的 domain，用于简单 cookie jar */
export function cookieDomain(url: string): string {
  const scheme = url.indexOf('://');
  const start = scheme >= 0 ? scheme + 3 : 0;
  const rest = url.substring(start);
  let end = rest.length;
  const slash = rest.indexOf('/');
  if (slash >= 0) {
    end = slash;
  }
  const host = rest.substring(0, end).split(':')[0];
  const parts = host.split('.');
  if (parts.length >= 2) {
    return parts[parts.length - 2] + '.' + parts[parts.length - 1];
  }
  return host;
}

export function nowText(): string {
  const d = new Date();
  const h = d.getHours();
  if (h < 6) {
    return '夜深了';
  }
  if (h < 11) {
    return '早上好';
  }
  if (h < 14) {
    return '中午好';
  }
  if (h < 18) {
    return '下午好';
  }
  return '晚上好';
}

export function dateText(): string {
  const d = new Date();
  const week = ['日', '一', '二', '三', '四', '五', '六'];
  return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日 · 周' + week[d.getDay()];
}
