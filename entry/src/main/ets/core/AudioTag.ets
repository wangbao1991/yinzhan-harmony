import { fileIo as fs } from '@kit.CoreFileKit';
import util from '@ohos.util';
import { SongInfo } from '../common/Models';

/**
 * 下载歌曲的「文件内标签」写入器（v1.0 · 纯 ArkTS / 零三方依赖）。
 *
 * 为什么要有这一层：Downloader 以前只是把音源返回的字节原样 copyFileSync 落盘，
 * 歌名 / 歌手只体现在文件名和 App 自己的下载记录里。文件一旦拷到别的设备、
 * 或用系统音乐 App 打开，就是一首「未知 artists / 未知标题」、没有歌词的裸音频。
 *
 * 本模块在落盘后把元信息真正写进音频容器本身：
 *   - mp3  → ID3v2.3 标签：TIT2 标题 / TPE1 歌手 / TALB 专辑 / USLT 歌词(LRC 原文)
 *   - flac → Vorbis Comment 元数据块：TITLE / ARTIST / ALBUM / LYRICS
 *   - 其余容器（m4a / ogg / wav / 未知）不动音频字节，避免手写 atom/page 结构损坏文件。
 * 下载目录始终只产出「一个」歌曲文件：mp3 / flac 的歌词直接内嵌在这个文件内部，
 * 不额外生成任何同名 .lrc 之类的附属文件；其余格式不带歌词，同样也不多出文件。
 *
 * 四条硬约束：
 *   ① 幂等：embed 可被重复调用（先写元数据、歌词异步补齐后再写一次）。
 *      mp3 会剥离并重建 ID3、flac 会合并已有 VORBIS_COMMENT，不会叠出两份标签。
 *   ② 不破坏原文件：mp3 保留原有的 APIC 封面等无关帧；flac 保留原有 comment 字段。
 *      写盘采用「整体重写 + 失败回滚原字节」，任何异常都不留下半截文件。
 *   ③ 绝不因标签失败连累下载：所有异常由 Downloader 侧 try/catch 兜住，只记日志。
 *   ④ 单文件：不写外挂 .lrc；每次 embed 顺手清掉旧版本遗留的同名 .lrc。
 */

interface TagMeta {
  title: string;
  artist: string;
  album: string;
}

interface Id3Frame {
  id: string;
  body: Uint8Array;
}

interface FlacBlock {
  type: number;
  last: boolean;
  body: Uint8Array;
}

interface FlacParsed {
  blocks: FlacBlock[];
  audioOffset: number;
}

export class AudioTag {
  private static encoder = util.TextEncoder.create('utf-8');

  /**
   * 把歌曲信息（及可选 LRC 歌词）写进「同一个」音频文件内部。
   * 返回是否真的把字节写进了文件（mp3 / flac 为 true）。
   * 不再生成外挂 .lrc；顺手清掉旧版本可能遗留的同名 .lrc，保证下载目录只有一个文件。
   */
  static embed(path: string, format: string, song: SongInfo, lyricLrc: string): boolean {
    const meta: TagMeta = {
      title: song.name,
      artist: song.singer,
      album: song.album.length > 0 ? song.album : (song.albumName ?? '')
    };
    AudioTag.removeSidecarLrc(path);
    if (format === 'mp3') {
      return AudioTag.writeMp3(path, meta, lyricLrc);
    }
    if (format === 'flac') {
      return AudioTag.writeFlac(path, meta, lyricLrc);
    }
    // m4a / ogg / wav / unknown：容器结构复杂，不动音频字节也不带歌词，仍是单文件
    return false;
  }

  /* ---------------- 文件级：整读 / 整写（带回滚） ---------------- */

  private static utf8(text: string): Uint8Array {
    return AudioTag.encoder.encodeInto(text);
  }

  private static toBuffer(bytes: Uint8Array): ArrayBuffer {
    const buf = new ArrayBuffer(bytes.length);
    const view = new Uint8Array(buf);
    view.set(bytes);
    return buf;
  }

  private static concat(parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const part of parts) {
      total += part.length;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      out.set(part, offset);
      offset += part.length;
    }
    return out;
  }

  private static be32(n: number): Uint8Array {
    const out = new Uint8Array(4);
    out[0] = (n >>> 24) & 0xff;
    out[1] = (n >>> 16) & 0xff;
    out[2] = (n >>> 8) & 0xff;
    out[3] = n & 0xff;
    return out;
  }

  private static le32(n: number): Uint8Array {
    const out = new Uint8Array(4);
    out[0] = n & 0xff;
    out[1] = (n >>> 8) & 0xff;
    out[2] = (n >>> 16) & 0xff;
    out[3] = (n >>> 24) & 0xff;
    return out;
  }

  private static readLe32(data: Uint8Array, offset: number): number {
    return (data[offset] | (data[offset + 1] << 8) |
      (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
  }

  private static readAll(path: string): Uint8Array {
    const stat = fs.statSync(path);
    const size = stat.size;
    const buf = new ArrayBuffer(size);
    const fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(fd.fd, buf, { length: size });
    } finally {
      fs.closeSync(fd);
    }
    return new Uint8Array(buf);
  }

  /**
   * 整体重写。失败时把读进内存的原始字节写回去，保证不会留下半截 / 空文件。
   * 这里不用「临时文件 + rename」：公共 Download 目录里 rename 覆盖语义不统一，
   * 原地 TRUNC + 内存回滚更可控。
   */
  private static rewrite(path: string, fresh: Uint8Array, original: Uint8Array): void {
    try {
      const fd = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(fd.fd, AudioTag.toBuffer(fresh));
      } finally {
        fs.closeSync(fd);
      }
    } catch (e) {
      try {
        const back = fs.openSync(path,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(back.fd, AudioTag.toBuffer(original));
        } finally {
          fs.closeSync(back);
        }
      } catch (rollbackError) {
        console.error('[AudioTag] 回滚原文件失败 ' + String(rollbackError));
      }
      throw new Error('写入标签失败，已回滚原文件：' + String(e));
    }
  }

  /**
   * 清掉旧版本遗留的同名 .lrc（早前版本会额外写一份外挂歌词）。
   * 只针对本次下载的这一首，不扫描目录、不碰其它文件；不存在时静默忽略。
   */
  private static removeSidecarLrc(path: string): void {
    const dot = path.lastIndexOf('.');
    const base = dot > 0 ? path.substring(0, dot) : path;
    const lrcPath = base + '.lrc';
    try {
      fs.unlinkSync(lrcPath);
    } catch (e) {
      // 新版本本来就不写，绝大多数情况是不存在，静默忽略
    }
  }

  /* ---------------- MP3：ID3v2.3 ---------------- */

  /** ID3v2 标签体大小（synchsafe 28bit） */
  private static id3Size(data: Uint8Array): number {
    if (data.length < 10 || data[0] !== 0x49 || data[1] !== 0x44 || data[2] !== 0x33) {
      return -1;
    }
    return (data[6] & 0x7f) * 2097152 + (data[7] & 0x7f) * 16384 +
      (data[8] & 0x7f) * 128 + (data[9] & 0x7f);
  }

  /** 去掉原有 ID3v2 标签，返回纯 MPEG 音频字节 */
  private static stripId3(data: Uint8Array): Uint8Array {
    const size = AudioTag.id3Size(data);
    if (size < 0) {
      return data;
    }
    let end = 10 + size;
    if ((data[5] & 0x10) !== 0) {
      end += 10; // v2.4 footer
    }
    if (end > data.length) {
      return data; // 头损坏，宁可不改
    }
    return data.subarray(end);
  }

  /**
   * 解析原有 ID3v2 帧，供重建时保留 APIC 封面等无关帧。
   * v2.3 帧大小是普通 BE32；v2.4 是 synchsafe —— 按主版本分别解码。
   */
  private static parseId3Frames(data: Uint8Array): Id3Frame[] {
    const frames: Id3Frame[] = [];
    const size = AudioTag.id3Size(data);
    if (size < 0) {
      return frames;
    }
    const major = data[3];
    let p = 10;
    const end = Math.min(10 + size, data.length);
    while (p + 10 <= end) {
      const id = String.fromCharCode(data[p], data[p + 1], data[p + 2], data[p + 3]);
      let frameSize = 0;
      if (major === 4) {
        frameSize = (data[p + 4] & 0x7f) * 2097152 + (data[p + 5] & 0x7f) * 16384 +
          (data[p + 6] & 0x7f) * 128 + (data[p + 7] & 0x7f);
      } else {
        frameSize = data[p + 4] * 16777216 + data[p + 5] * 65536 +
          data[p + 6] * 256 + data[p + 7];
      }
      if (frameSize <= 0 || p + 10 + frameSize > end) {
        break; // 撞到 padding 或坏帧，到此为止
      }
      const frame: Id3Frame = { id: id, body: data.subarray(p + 10, p + 10 + frameSize) };
      frames.push(frame);
      p += 10 + frameSize;
    }
    return frames;
  }

  private static id3Frame(id: string, body: Uint8Array): Uint8Array {
    const head = new Uint8Array(10);
    head[0] = id.charCodeAt(0);
    head[1] = id.charCodeAt(1);
    head[2] = id.charCodeAt(2);
    head[3] = id.charCodeAt(3);
    head.set(AudioTag.be32(body.length), 4);
    head[8] = 0;
    head[9] = 0;
    return AudioTag.concat([head, body]);
  }

  /** 文本帧：0x03 表示 UTF-8（ID3v2.3） */
  private static id3Text(id: string, text: string): Uint8Array {
    const enc = new Uint8Array(1);
    enc[0] = 0x03;
    return AudioTag.id3Frame(id, AudioTag.concat([enc, AudioTag.utf8(text)]));
  }

  /** USLT 非同步歌词：编码 + 语言(eng) + 空描述符(NUL) + LRC 原文 */
  private static id3Uslt(lrc: string): Uint8Array {
    const head = new Uint8Array(5);
    head[0] = 0x03;
    head[1] = 0x65; // e
    head[2] = 0x6e; // n
    head[3] = 0x67; // g
    head[4] = 0x00; // 内容描述符终止
    return AudioTag.id3Frame('USLT', AudioTag.concat([head, AudioTag.utf8(lrc)]));
  }

  private static id3Tag(meta: TagMeta, lrc: string, kept: Id3Frame[]): Uint8Array {
    const frames: Uint8Array[] = [];
    // 保留原有帧里我们不会覆盖的部分（封面 APIC / 曲风 TCON / 年份 TYER 等）
    for (const frame of kept) {
      if (frame.id === 'TIT2' || frame.id === 'TPE1' || frame.id === 'TALB' ||
        frame.id === 'USLT' || frame.id === 'SYLT') {
        continue;
      }
      frames.push(AudioTag.id3Frame(frame.id, frame.body));
    }
    frames.push(AudioTag.id3Text('TIT2', meta.title));
    if (meta.artist.length > 0) {
      frames.push(AudioTag.id3Text('TPE1', meta.artist));
    }
    if (meta.album.length > 0) {
      frames.push(AudioTag.id3Text('TALB', meta.album));
    }
    if (lrc.length > 0) {
      frames.push(AudioTag.id3Uslt(lrc));
    }
    const body = AudioTag.concat(frames);
    const size = body.length;
    const header = new Uint8Array(10);
    header[0] = 0x49; // I
    header[1] = 0x44; // D
    header[2] = 0x33; // 3
    header[3] = 0x03; // v2.3
    header[4] = 0x00; // revision
    header[5] = 0x00; // flags
    header[6] = (size >>> 21) & 0x7f;
    header[7] = (size >>> 14) & 0x7f;
    header[8] = (size >>> 7) & 0x7f;
    header[9] = size & 0x7f;
    return AudioTag.concat([header, body]);
  }

  private static writeMp3(path: string, meta: TagMeta, lrc: string): boolean {
    const original = AudioTag.readAll(path);
    const kept = AudioTag.parseId3Frames(original);
    const audio = AudioTag.stripId3(original);
    if (audio.length === 0) {
      return false;
    }
    const fresh = AudioTag.concat([AudioTag.id3Tag(meta, lrc, kept), audio]);
    AudioTag.rewrite(path, fresh, original);
    return true;
  }

  /* ---------------- FLAC：Vorbis Comment 元数据块 ---------------- */

  /** 解析 fLaC 之后的所有 metadata block，并记下音频帧起点 */
  private static parseFlac(data: Uint8Array): FlacParsed | null {
    if (data.length < 42 || data[0] !== 0x66 || data[1] !== 0x4c ||
      data[2] !== 0x61 || data[3] !== 0x43) {
      return null;
    }
    const blocks: FlacBlock[] = [];
    let offset = 4;
    while (offset + 4 <= data.length) {
      const head = data[offset];
      const type = head & 0x7f;
      const last = (head & 0x80) !== 0;
      const len = (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
      const start = offset + 4;
      const end = start + len;
      if (end > data.length) {
        return null; // 块长度越界，宁可不改
      }
      const block: FlacBlock = { type: type, last: last, body: data.subarray(start, end) };
      blocks.push(block);
      offset = end;
      if (last) {
        break;
      }
    }
    if (blocks.length === 0) {
      return null;
    }
    const parsed: FlacParsed = { blocks: blocks, audioOffset: offset };
    return parsed;
  }

  /** 这条 comment 是否属于我们要覆盖的字段 */
  private static isOverridden(entry: Uint8Array): boolean {
    const keys: string[] = ['TITLE=', 'ARTIST=', 'ALBUM=', 'LYRICS=', 'UNSYNCEDLYRICS='];
    for (const key of keys) {
      if (entry.length < key.length) {
        continue;
      }
      let same = true;
      for (let i = 0; i < key.length; i++) {
        const c = entry[i];
        const upper = (c >= 0x61 && c <= 0x7a) ? c - 32 : c;
        if (upper !== key.charCodeAt(i)) {
          same = false;
          break;
        }
      }
      if (same) {
        return true;
      }
    }
    return false;
  }

  /**
   * 生成 VORBIS_COMMENT 块体：vendor_length + vendor + count + 若干 length+KEY=value。
   * 已有 comment 里未覆盖的字段（如 DATE / GENRE / 官方 tag）原样保留。
   */
  private static vorbisBody(existing: Uint8Array | null, meta: TagMeta, lrc: string): Uint8Array {
    const kept: Uint8Array[] = [];
    if (existing !== null && existing.length >= 8) {
      let p = 0;
      const vendorLen = AudioTag.readLe32(existing, 0);
      p = 4 + vendorLen;
      if (p + 4 <= existing.length) {
        const count = AudioTag.readLe32(existing, p);
        p += 4;
        for (let i = 0; i < count; i++) {
          if (p + 4 > existing.length) {
            break;
          }
          const len = AudioTag.readLe32(existing, p);
          p += 4;
          if (p + len > existing.length) {
            break;
          }
          const entry = existing.subarray(p, p + len);
          p += len;
          if (!AudioTag.isOverridden(entry)) {
            kept.push(entry);
          }
        }
      }
    }
    const entries: Uint8Array[] = [];
    entries.push(AudioTag.utf8('TITLE=' + meta.title));
    if (meta.artist.length > 0) {
      entries.push(AudioTag.utf8('ARTIST=' + meta.artist));
    }
    if (meta.album.length > 0) {
      entries.push(AudioTag.utf8('ALBUM=' + meta.album));
    }
    if (lrc.length > 0) {
      entries.push(AudioTag.utf8('LYRICS=' + lrc));
    }
    const vendor = AudioTag.utf8('音栈 1.0');
    const parts: Uint8Array[] = [];
    parts.push(AudioTag.le32(vendor.length), vendor);
    parts.push(AudioTag.le32(kept.length + entries.length));
    for (const entry of kept) {
      parts.push(AudioTag.le32(entry.length), entry);
    }
    for (const entry of entries) {
      parts.push(AudioTag.le32(entry.length), entry);
    }
    return AudioTag.concat(parts);
  }

  private static writeFlac(path: string, meta: TagMeta, lrc: string): boolean {
    const original = AudioTag.readAll(path);
    const parsed = AudioTag.parseFlac(original);
    if (parsed === null) {
      return false;
    }
    const blocks: FlacBlock[] = parsed.blocks;
    let index = -1;
    for (let i = 0; i < blocks.length; i++) {
      if (blocks[i].type === 4) {
        index = i;
        break;
      }
    }
    const existing = index >= 0 ? blocks[index].body : null;
    const body = AudioTag.vorbisBody(existing, meta, lrc);
    const comment: FlacBlock = { type: 4, last: false, body: body };
    if (index >= 0) {
      blocks[index] = comment;
    } else {
      // STREAMINFO 必须是第一个块，VORBIS_COMMENT 紧随其后
      const at = blocks.length > 0 ? 1 : 0;
      blocks.splice(at, 0, comment);
    }
    // 只有最后一个块能带 last 标志：原 STREAMINFO 可能是 last，必须清掉
    for (let i = 0; i < blocks.length; i++) {
      const old = blocks[i];
      const fixed: FlacBlock = { type: old.type, last: i === blocks.length - 1, body: old.body };
      blocks[i] = fixed;
    }
    const parts: Uint8Array[] = [];
    parts.push(AudioTag.utf8('fLaC'));
    for (const block of blocks) {
      const head = new Uint8Array(4);
      head[0] = (block.last ? 0x80 : 0x00) | (block.type & 0x7f);
      const len = block.body.length;
      head[1] = (len >>> 16) & 0xff;
      head[2] = (len >>> 8) & 0xff;
      head[3] = len & 0xff;
      parts.push(head, block.body);
    }
    parts.push(original.subarray(parsed.audioOffset));
    const fresh = AudioTag.concat(parts);
    AudioTag.rewrite(path, fresh, original);
    return true;
  }
}
