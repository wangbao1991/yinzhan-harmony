import { LyricDoc, LyricLine, emptyLyric } from '../common/Models';

function timeTagMs(min: string, sec: string, frac: string): number {
  const m = Number.parseInt(min);
  const s = Number.parseInt(sec);
  let ms = 0;
  if (frac.length > 0) {
    if (frac.length === 1) {
      ms = Number.parseInt(frac) * 100;
    } else if (frac.length === 2) {
      ms = Number.parseInt(frac) * 10;
    } else {
      ms = Number.parseInt(frac.substring(0, 3));
    }
  }
  return m * 60000 + s * 1000 + ms;
}

/**
 * 解析 LRC。支持一行多个时间标签、翻译合并、无时间轴纯文本。
 * 返回的 time 单位为秒。
 */
export function parseLrc(raw: string, translation: string = ''): LyricDoc {
  const doc = emptyLyric();
  doc.raw = raw;
  if (raw.trim().length === 0) {
    return doc;
  }
  const transMap: Map<string, string> = new Map<string, string>();
  if (translation.trim().length > 0) {
    const transLines = splitLines(translation);
    for (const line of transLines) {
      const parsed = splitTimeText(line);
      if (parsed.time >= 0 && parsed.text.length > 0) {
        transMap.set(parsed.time.toFixed(2), parsed.text);
      }
    }
  }
  const map: Map<string, LyricLine> = new Map<string, LyricLine>();
  const lines = splitLines(raw);
  let tagCount = 0;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const times = extractTimes(trimmed);
    if (times.length === 0) {
      // 元信息标签 [ti:] [ar:] 等直接跳过
      if (trimmed.startsWith('[') && trimmed.indexOf(']') > 0 && trimmed.indexOf(':') > 0) {
        continue;
      }
      continue;
    }
    tagCount += times.length;
    // 去掉 [时间轴] 与 KRC/增强 LRC 的 <逐字时间> 标记，避免歌词里残留时间戳
    const text = trimmed.replace(/\[[^\]]*\]/g, '')
      .replace(/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g, '')
      .trim();
    if (text.length === 0) {
      continue;
    }
    for (const time of times) {
      const key = time.toFixed(2);
      const item: LyricLine = { time: time, text: text, trans: transMap.get(key) ?? '' };
      map.set(key, item);
      if (item.trans.length > 0) {
        doc.hasTrans = true;
      }
    }
  }
  if (tagCount === 0) {
    // 没有一句时间轴，先判断是不是把 HTML 错误页 / JSON 响应当成歌词了：
    // 咪咕 v3 接口下线后返回 301 跳转页，正文是 <!doctype html>…，
    // 以前会被当作「无时间轴纯文本歌词」逐行显示出来。
    if (looksLikeMarkup(raw) || looksLikeNonLyric(raw)) {
      return doc;
    }
    // 纯文本歌词：按行展示，不做滚动高亮
    doc.plain = true;
    const plainLines = splitLines(raw);
    for (const line of plainLines) {
      const text = line.replace(/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g, '').trim();
      if (text.length > 0) {
        doc.lines.push({ time: -1, text: text, trans: '' });
      }
    }
    return doc;
  }
  const keys: string[] = [];
  map.forEach((value: LyricLine, key: string) => {
    keys.push(key);
  });
  keys.sort((a: string, b: string): number => Number.parseFloat(a) - Number.parseFloat(b));
  for (const key of keys) {
    const item = map.get(key);
    if (item !== undefined) {
      doc.lines.push(item);
    }
  }
  return doc;
}

function splitLines(text: string): string[] {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
}

/**
 * 判断一段「没有时间轴」的文本是不是网页 / 接口响应，而不是歌词。
 * 只看开头的标签或整体形态，避免误伤正文里偶尔出现的尖括号。
 */
export function looksLikeMarkup(text: string): boolean {
  const head = text.substring(0, 500).toLowerCase();
  const tags: string[] = ['<!doctype', '<html', '<head', '<body', '<meta', '<script',
    '<div', '<center', '<title', '<p>', '<br'];
  for (const tag of tags) {
    if (head.indexOf(tag) >= 0) {
      return true;
    }
  }
  const trimmed = head.trim();
  // {"code":"299996","info":"路由请求不支持"} 这类 JSON 响应
  if ((trimmed.startsWith('{') || trimmed.startsWith('[')) && text.indexOf('":') >= 0) {
    return true;
  }
  return false;
}

/**
 * 判断一段文本是不是「明显不是歌词」：URL / 音频直链 / 接口报错串。
 *
 * 音源脚本的 lyric 动作偶尔把播放链接或错误页塞进 lyric 字段，例如
 * `{"lyric":"http://car-lv.kuwo.cn/.../trackmedia/xxx.mgg"}`。
 * 这类文本没有时间轴，parseLrc 会走「无时间轴纯文本歌词」分支逐行显示，
 * 于是播放页出现一整屏网址。looksLikeMarkup 只认 HTML / JSON 标签，
 * 认不出 URL，所以这里单独补一层内容校验。
 */
export function looksLikeNonLyric(text: string): boolean {
  const head = text.substring(0, 600).toLowerCase();
  if (head.indexOf('http://') >= 0 || head.indexOf('https://') >= 0 ||
    head.indexOf('ftp://') >= 0 || head.indexOf('www.') >= 0) {
    return true;
  }
  if (/\.(?:mgg|mp3|flac|m4a|aac|ogg|wav|ape|wma|m3u8|mp4)(?:\?|#|\s|$)/.test(head)) {
    return true;
  }
  if (/(?:tp=error|error request|音乐查询失败|"code"\s*:|"status"\s*:\s*301|请求过于频繁)/.test(head)) {
    return true;
  }
  // 无时间轴、只有一两行且单行超长，基本是一整条链接 / 报错串，不是歌词
  if (!/\[\d{1,3}:\d{1,2}/.test(text)) {
    const lines = text.split('\n');
    let longest = 0;
    for (const line of lines) {
      longest = Math.max(longest, line.trim().length);
    }
    if (lines.length <= 2 && longest > 80) {
      return true;
    }
  }
  return false;
}

function extractTimes(line: string): number[] {
  const times: number[] = [];
  const re = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  let match = re.exec(line);
  while (match !== null) {
    const frac = match[3] ?? '';
    times.push(timeTagMs(match[1], match[2], frac) / 1000);
    match = re.exec(line);
  }
  return times;
}

interface TimeText {
  time: number;
  text: string;
}

function splitTimeText(line: string): TimeText {
  const times = extractTimes(line);
  const text = line.replace(/\[[^\]]*\]/g, '').trim();
  if (times.length === 0) {
    return { time: -1, text: text };
  }
  return { time: times[0], text: text };
}

/** 当前时间对应的歌词下标；没有精确匹配时返回最后一句已唱过的 */
export function lyricIndexAt(lines: LyricLine[], seconds: number): number {
  if (lines.length === 0) {
    return -1;
  }
  if (lines[0].time < 0) {
    return -1;
  }
  let low = 0;
  let high = lines.length - 1;
  let result = -1;
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    if (lines[mid].time <= seconds) {
      result = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return result;
}
