import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { PrefKeys } from '../common/Constants';
import { SourceBackupItem } from '../common/Models';
import { Store } from './Store';
import { Library } from './Library';
import { PlayStats } from './PlayStats';
import { Settings } from './Settings';
import { ImportIntent } from './ImportIntent';
import { SourceRepo } from './SourceRepo';

/**
 * 本地数据备份 / 恢复（v2.22 建立，v2.39 把音源脚本纳入范围）。
 *
 * 纯端侧：一个 JSON 文件，走系统保存 / 选择面板，不联网、不引三方依赖。
 * 备份范围分两段，都用白名单 / 结构化校验收口：
 *   - entries：用户数据 + 设置偏好（STRING/NUMBER/BOOL 三张白名单）；
 *   - scripts：音源脚本，元数据与**脚本正文一起**带走。恢复时把 code 写回
 *     files/sources/<id>.js、重建 v4_sources / v4_active_source、重新注入运行时，
 *     而不是只备份一个元数据字符串、恢复后满屏「脚本文件丢失，请重新导入」（铁律 2）。
 * 仍不含：本地音乐与下载记录（沙箱文件路径，恢复后只会得到一堆死链）、
 * 播放队列、上次进度、自检时间戳等运行时状态。
 * 白名单同时是导入的安全边界：文件里任何不在名单内的 key 一律跳过，
 * 绝不把外部文件内容直接写进 preferences；scripts 段另做 id / 正文校验。
 * 老备份（schema 1、无 scripts 段）照常恢复，且完全不碰现有音源。
 */

type BackupValue = string | number | boolean;

interface BackupEntry {
  k: string;
  t: string;
  v: BackupValue;
}

interface BackupFile {
  app: string;
  schema: number;
  createdAt: number;
  entries: BackupEntry[];
  /** v2.39 起：音源脚本（含正文）。可选，老备份没有这一段 */
  scripts?: SourceBackupItem[];
  /** 备份时的首选音源 id */
  activeSource?: string;
}

export interface RestoreResult {
  ok: boolean;
  text: string;
}

const SCHEMA: number = 1;
const APP_TAG: string = 'yinzhan';

/** 字符串型：用户数据（JSON 文本）与字符串偏好 */
const STRING_KEYS: string[] = [
  PrefKeys.FAVORITES,
  PrefKeys.FAVORITE_SHEETS,
  PrefKeys.PLAYLISTS,
  PrefKeys.HISTORY,
  PrefKeys.SEARCH_HISTORY,
  PrefKeys.PLAY_STATS,
  PrefKeys.QUALITY,
  PrefKeys.SOURCE_MODE,
  PrefKeys.SEARCH_PLATFORMS,
  PrefKeys.SEARCH_SOURCE,
  PrefKeys.DISCOVER_PLATFORM
];

/** 数值型偏好 */
const NUMBER_KEYS: string[] = [
  PrefKeys.THEME_MODE,
  PrefKeys.LIGHT_SENSE,
  PrefKeys.LYRIC_SIZE,
  PrefKeys.LYRIC_ALIGN,
  PrefKeys.PLAY_MODE
];

/** 布尔型偏好 */
const BOOL_KEYS: string[] = [
  PrefKeys.AUTO_PLAY,
  PrefKeys.REMEMBER_POS,
  PrefKeys.IGNORE_INTERRUPT,
  PrefKeys.SHOW_TRANS,
  PrefKeys.DOWNLOAD_DOWNGRADE,
  PrefKeys.AUTO_CHECK_SOURCES,
  PrefKeys.REMEMBER_SOURCE,
  PrefKeys.VERIFY_BEFORE_DOWNLOAD,
  PrefKeys.AUTO_FALLBACK_ON_FAILURE,
  PrefKeys.PRELOAD_NEXT
];

export class Backup {
  private static busy: boolean = false;

  /** 生成备份 JSON 文本。空值也照实写进去——备份是完整快照，恢复即覆盖 */
  static snapshot(): string {
    const store = Store.get();
    const entries: BackupEntry[] = [];
    for (const k of STRING_KEYS) {
      entries.push({ k: k, t: 's', v: store.getString(k, '') });
    }
    for (const k of NUMBER_KEYS) {
      entries.push({ k: k, t: 'n', v: store.getNumber(k, 0) });
    }
    for (const k of BOOL_KEYS) {
      entries.push({ k: k, t: 'b', v: store.getBool(k, false) });
    }
    const repo = SourceRepo.get();
    const file: BackupFile = {
      app: APP_TAG,
      schema: SCHEMA,
      createdAt: Date.now(),
      entries: entries,
      scripts: repo.exportScripts(),
      activeSource: repo.getActiveId()
    };
    return JSON.stringify(file);
  }

  static count(): number {
    return STRING_KEYS.length + NUMBER_KEYS.length + BOOL_KEYS.length;
  }

  /** 本次会被备份的音源脚本数（正文真实存在才算，文件已丢的死链不进备份） */
  static scriptCount(): number {
    return SourceRepo.get().exportScripts().length;
  }

  /** 导出：交给系统保存面板，用户选目录即可 */
  static async exportTo(context: common.UIAbilityContext): Promise<string> {
    if (Backup.busy) {
      return '';
    }
    Backup.busy = true;
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['音栈备份-' + Backup.stamp() + '.json'];
      options.fileSuffixChoices = ['.json'];
      const uris = await viewPicker.save(options);
      if (uris.length === 0) {
        return '';
      }
      const text = Backup.snapshot();
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
      return '已备份 ' + Backup.count().toString() + ' 项数据、' +
        Backup.scriptCount().toString() + ' 个音源脚本';
    } finally {
      Backup.busy = false;
    }
  }

  /** 恢复：选一个 .json，校验后按白名单写回 */
  static async restoreFrom(context: common.UIAbilityContext): Promise<RestoreResult> {
    if (Backup.busy) {
      return { ok: false, text: '' };
    }
    Backup.busy = true;
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const uris = await viewPicker.select(options);
      if (uris.length === 0) {
        return { ok: false, text: '' };
      }
      const text = ImportIntent.readText(uris[0]);
      return await Backup.apply(text);
    } finally {
      Backup.busy = false;
    }
  }

  /** 解析并应用备份文本；返回可直接展示的结果文案 */
  static async apply(text: string): Promise<RestoreResult> {
    if (text.trim().length === 0) {
      return { ok: false, text: '备份文件是空的' };
    }
    let data: BackupFile;
    try {
      data = JSON.parse(text) as BackupFile;
    } catch (e) {
      return { ok: false, text: '这不是有效的备份文件（JSON 解析失败）' };
    }
    if (data.app !== APP_TAG) {
      return { ok: false, text: '这不是音栈的备份文件' };
    }
    if (data.schema !== SCHEMA) {
      return { ok: false, text: '备份文件版本不兼容，无法恢复' };
    }
    if (!Array.isArray(data.entries)) {
      return { ok: false, text: '备份文件内容不完整' };
    }

    let written: number = 0;
    let skipped: number = 0;
    const store = Store.get();
    for (const entry of data.entries) {
      if (typeof entry.k !== 'string' || typeof entry.t !== 'string') {
        skipped++;
        continue;
      }
      const expected = Backup.kindOf(entry.k);
      if (expected.length === 0 || expected !== entry.t || !Backup.typeMatches(entry.t, entry.v)) {
        skipped++;
        continue;
      }
      store.put(entry.k, entry.v as BackupValue);
      written++;
    }

    // v2.39：音源脚本（可选段）。只有备份里确实带脚本才覆盖当前音源列表；
    // 老备份没有这一段、或当时一个音源都没有，都完全不碰现有音源，避免误清空。
    let restoredScripts: number = 0;
    let scriptError: string = '';
    if (Array.isArray(data.scripts) && (data.scripts as SourceBackupItem[]).length > 0) {
      const activeId: string = typeof data.activeSource === 'string' ? (data.activeSource as string) : '';
      try {
        restoredScripts = await SourceRepo.get().restoreFromBackup(
          data.scripts as SourceBackupItem[], activeId);
      } catch (e) {
        scriptError = e instanceof Error ? e.message : String(e);
      }
    }
    if (written === 0 && restoredScripts === 0) {
      return { ok: false, text: '没有可恢复的数据（文件里没有音栈认识的条目）' };
    }
    Backup.refreshAfterRestore();
    const tail = skipped > 0 ? '，跳过 ' + skipped.toString() + ' 项不认识的条目' : '';
    const scriptTail = restoredScripts > 0 ? '、' + restoredScripts.toString() + ' 个音源脚本' : '';
    const errTail = scriptError.length > 0 ? '（音源脚本恢复失败：' + scriptError + '）' : '';
    return { ok: true, text: '已恢复 ' + written.toString() + ' 项数据' + scriptTail + tail + errTail };
  }

  /**
   * 恢复后刷新内存态：Library / PlayStats 都是单例、启动时各读一次盘，
   * 不重读的话界面还会显示旧收藏。AppStorage 里的派生偏好同理。
   * 音源侧的内存态 / 运行时注入由 SourceRepo.restoreFromBackup() 自己收口。
   */
  static refreshAfterRestore(): void {
    Store.get().flush();
    Library.get().reload();
    PlayStats.get().reload();
    const s = Settings.get();
    AppStorage.setOrCreate('qualityPref', s.quality());
    AppStorage.setOrCreate('lightSense', s.lightSense());
    AppStorage.setOrCreate('lyricSize', s.lyricSize());
    AppStorage.setOrCreate('discoverPlatform', s.discoverPlatform());
  }

  private static kindOf(key: string): string {
    if (STRING_KEYS.indexOf(key) >= 0) {
      return 's';
    }
    if (NUMBER_KEYS.indexOf(key) >= 0) {
      return 'n';
    }
    if (BOOL_KEYS.indexOf(key) >= 0) {
      return 'b';
    }
    return '';
  }

  private static typeMatches(kind: string, value: BackupValue): boolean {
    if (kind === 's') {
      return typeof value === 'string';
    }
    if (kind === 'n') {
      return typeof value === 'number';
    }
    if (kind === 'b') {
      return typeof value === 'boolean';
    }
    return false;
  }

  private static stamp(): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return d.getFullYear().toString() + pad(d.getMonth() + 1) + pad(d.getDate()) +
      '-' + pad(d.getHours()) + pad(d.getMinutes());
  }
}
