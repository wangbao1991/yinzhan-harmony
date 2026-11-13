import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { LocalSong, SongInfo, newSong, secondsToInterval } from '../common/Models';
import { PrefKeys } from '../common/Constants';
import { Store } from './Store';

interface LocalMeta {
  title: string;
  artist: string;
  album: string;
  duration: number;
}

/**
 * 本地音乐：从系统文件选择器导入音频，拷进沙箱（files/local_music），
 * 用 AVMetadataExtractor 读标题/歌手/专辑/时长，读不到就按「歌手 - 歌名」解析。
 */
export class LocalRepo {
  private static instance: LocalRepo = new LocalRepo();
  static get(): LocalRepo {
    return LocalRepo.instance;
  }

  private songs: LocalSong[] = [];
  private dir: string = '';
  private context: common.UIAbilityContext | null = null;
  private listeners: Array<() => void> = [];

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.context !== null) {
      return;
    }
    this.context = context;
    this.dir = context.filesDir + '/local_music';
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
    } catch (e) {
      console.error('[Local] 创建目录失败 ' + String(e));
    }
    const text = Store.get().getString(PrefKeys.LOCAL_SONGS, '[]');
    try {
      this.songs = JSON.parse(text) as LocalSong[];
    } catch (e) {
      this.songs = [];
    }
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
  }

  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
    // 一级页常驻后不会重建，靠这个版本号让音乐库的「本地音乐 N 首」跟着变
    AppStorage.setOrCreate('localVersion', Date.now());
  }

  list(): LocalSong[] {
    return this.songs;
  }

  count(): number {
    return this.songs.length;
  }

  usedBytes(): number {
    let total = 0;
    for (const song of this.songs) {
      total += song.size;
    }
    return total;
  }

  pathOf(songId: string): string {
    for (const song of this.songs) {
      if (song.id === songId) {
        return song.filePath;
      }
    }
    return '';
  }

  /** 转成播放器/列表通用的 SongInfo */
  toSongs(): SongInfo[] {
    const list: SongInfo[] = [];
    for (const song of this.songs) {
      const info = newSong('local');
      info.id = song.id;
      info.songmid = song.id;
      info.hash = song.id;
      info.name = song.name;
      info.singer = song.singer;
      info.album = song.album;
      info.albumName = song.album;
      info.duration = song.duration;
      info.interval = song.interval;
      info.cover = song.cover;
      info.url = song.filePath;
      info.quality = 'local';
      list.push(info);
    }
    return list;
  }

  async importFromPicker(): Promise<number> {
    const context = this.context;
    if (context === null) {
      return 0;
    }
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 50,
      fileSuffixFilters: ['音频|.mp3,.flac,.wav,.m4a,.aac,.ogg,.ape,.opus,.wma'],
      selectMode: picker.DocumentSelectMode.FILE
    };
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.select(options);
    let added = 0;
    for (const uri of uris) {
      try {
        if (await this.importOne(uri)) {
          added++;
        }
      } catch (e) {
        console.warn('[Local] 导入失败 ' + String(e));
      }
    }
    this.persist();
    this.notify();
    return added;
  }

  private async importOne(uri: string): Promise<boolean> {
    const ext = LocalRepo.extensionOf(uri);
    const baseName = LocalRepo.fileNameOf(uri);
    const id = 'lc_' + Date.now().toString() + '_' + Math.floor(Math.random() * 10000).toString();
    const target = this.dir + '/' + id + ext;
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    let size = 0;
    try {
      size = fs.statSync(src.fd).size;
      fs.copyFileSync(src.fd, target);
    } finally {
      fs.closeSync(src);
    }
    if (size === 0) {
      return false;
    }
    const meta = await this.readMetadata(target, size);
    const song: LocalSong = {
      id: id,
      name: meta.title.length > 0 ? meta.title : LocalRepo.titleFromName(baseName),
      singer: meta.artist.length > 0 ? meta.artist : LocalRepo.singerFromName(baseName),
      album: meta.album.length > 0 ? meta.album : '本地音乐',
      duration: meta.duration,
      interval: secondsToInterval(meta.duration),
      filePath: target,
      size: size,
      addedAt: Date.now(),
      cover: ''
    };
    this.songs.unshift(song);
    return true;
  }

  private async readMetadata(path: string, size: number): Promise<LocalMeta> {
    const result: LocalMeta = { title: '', artist: '', album: '', duration: 0 };
    let extractor: media.AVMetadataExtractor | null = null;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      const desc: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: size };
      extractor.fdSrc = desc;
      const meta = await extractor.fetchMetadata();
      result.title = meta.title ?? '';
      result.artist = meta.artist ?? '';
      result.album = meta.album ?? '';
      const ms = Number.parseInt(meta.duration ?? '0');
      result.duration = Number.isNaN(ms) ? 0 : Math.floor(ms / 1000);
    } catch (e) {
      console.info('[Local] 元数据读取失败 ' + String(e));
    } finally {
      if (extractor !== null) {
        try {
          await extractor.release();
        } catch (e) {
          // 释放失败不影响导入
        }
      }
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
    return result;
  }

  remove(id: string): void {
    const index = this.songs.findIndex((item: LocalSong): boolean => item.id === id);
    if (index < 0) {
      return;
    }
    try {
      fs.unlinkSync(this.songs[index].filePath);
    } catch (e) {
      console.info('[Local] 删除文件失败 ' + String(e));
    }
    this.songs.splice(index, 1);
    this.persist();
    this.notify();
  }

  /**
   * 批量删除（全选/多选）。
   * 逐条 remove() 会每删一首 persist + notify 一次：列表闪、Preferences 被刷 N 遍。
   * 这里删完一次性落盘、一次广播。
   */
  removeMany(ids: string[]): number {
    if (ids.length === 0) {
      return 0;
    }
    const keep: LocalSong[] = [];
    let count = 0;
    for (const song of this.songs) {
      if (ids.indexOf(song.id) >= 0) {
        try {
          fs.unlinkSync(song.filePath);
        } catch (e) {
          console.info('[Local] 删除文件失败 ' + String(e));
        }
        count++;
        continue;
      }
      keep.push(song);
    }
    if (count === 0) {
      return 0;
    }
    this.songs = keep;
    this.persist();
    this.notify();
    return count;
  }

  clear(): void {
    for (const song of this.songs) {
      try {
        fs.unlinkSync(song.filePath);
      } catch (e) {
        // 忽略
      }
    }
    this.songs = [];
    this.persist();
    this.notify();
  }

  private persist(): void {
    Store.get().put(PrefKeys.LOCAL_SONGS, JSON.stringify(this.songs));
  }

  private static extensionOf(uri: string): string {
    const idx = uri.lastIndexOf('.');
    if (idx < 0) {
      return '.mp3';
    }
    const ext = uri.substring(idx).toLowerCase();
    return ext.length <= 6 ? ext : '.mp3';
  }

  private static fileNameOf(uri: string): string {
    const clean = decodeURIComponent(uri);
    const idx = clean.lastIndexOf('/');
    const name = idx >= 0 ? clean.substring(idx + 1) : clean;
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  private static titleFromName(name: string): string {
    const idx = name.indexOf('-');
    return idx > 0 ? name.substring(idx + 1).trim() : name.trim();
  }

  private static singerFromName(name: string): string {
    const idx = name.indexOf('-');
    return idx > 0 ? name.substring(0, idx).trim() : '未知歌手';
  }
}
