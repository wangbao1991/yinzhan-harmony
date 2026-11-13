/**
 * v5「墨栈 Inkstack」设计系统
 *
 * 从「会发光的青绿玻璃」退成「不反光的纸墨陈列面」：表面中性无彩、不透明、
 * 无渐变、无外光晕；层级靠字阶 / 字重 / 1vp 发丝线 / 留白，不靠底色差与投影。
 * 专辑封面是唯一自由彩色区，饱和色相压缩成小面积「信号琥珀」。
 * 全站跟随 @StorageProp('isDark')，明确不引入 backgroundBlurStyle。
 *
 * 兼容说明：glass* / lightSense / palette 等符号名与签名全部保留（全站约 250 处
 * 调用点与静态自检依赖它们），但返回值统一收敛为「中性纸墨实色」—— 去光化在
 * 这一层一次完成，调用点无需改动。四级明度阶 cardAlt < bg < bgSoft < card。
 *
 * v2.80：青绿液态玻璃整套换肤引擎已连根删除 —— 界面固定为「纸墨」单一风格，
 * 下面所有取色/取材质函数只保留纸墨实色实现，不再有第二套主题分发。
 */

export interface Palette {
  /** 页面底色 */
  bg: string;
  /** 分组次级底 */
  bgSoft: string;
  /** 卡片（抬起面，最亮） */
  card: string;
  /** 卡片内次级容器 / 内嵌井（最暗） */
  cardAlt: string;
  /** 主文字（墨） */
  text: string;
  /** 次文字 */
  text2: string;
  /** 三级文字（已按 WCAG 修正，对 card 达 5.30:1） */
  text3: string;
  /** 装饰发丝线（结构性边界见 inkDividerStrong） */
  line: string;
  /** 信号主色：琥珀（浅 E29A26 / 深 F3B044） */
  primary: string;
  /** 信号色 12% / 15% 弱化底 */
  primarySoft: string;
  /** 反相墨块（徽标 / 收藏），非警示 */
  accent: string;
  /** 危险色：玫红 */
  danger: string;
  /** 成功色：墨绿 */
  success: string;
  /** 悬浮控件底色（中性实色，不透明） */
  glass: string;
  /** 悬浮控件结构性边界 */
  glassBorder: string;
  /** 中性紧投影 */
  shadow: string;
  /** 封面压暗遮罩（全站唯一允许的渐变用途） */
  scrim: string;
  /** 图标默认色 */
  icon: string;
  /** 封面占位起点（中性） */
  placeholderFrom: string;
  /** 封面占位终点（中性） */
  placeholderTo: string;
}

/** 浅色 · 暖骨白纸墨面 */
export const LIGHT: Palette = {
  bg: '#FFF1EFEA',
  bgSoft: '#FFF7F5F0',
  card: '#FFFDFCFA',
  cardAlt: '#FFE7E4DD',
  text: '#FF1B1A18',
  text2: '#FF5C5851',
  text3: '#FF6F6960',
  line: '#FFDEDAD2',
  primary: '#FFE29A26',
  primarySoft: '#1FE29A26',
  accent: '#FF1F1D19',
  danger: '#FFC0323C',
  success: '#FF1F7A55',
  glass: '#F0FDFCFA',
  glassBorder: '#FF817E7A',
  shadow: '#1C1B1A18',
  scrim: '#66000000',
  icon: '#FF5C5851',
  placeholderFrom: '#FFE7E4DD',
  placeholderTo: '#FFDEDAD2'
};

/** 深色 · 冷石墨纸墨面 */
export const DARK: Palette = {
  bg: '#FF0F1116',
  bgSoft: '#FF171A21',
  card: '#FF1E222A',
  cardAlt: '#FF0A0C10',
  text: '#FFF2F3F7',
  text2: '#FFA2A8B4',
  text3: '#FF878D96',
  line: '#FF2A2E37',
  primary: '#FFF3B044',
  primarySoft: '#26F3B044',
  accent: '#FFF0EEE8',
  danger: '#FFE4696E',
  success: '#FF4FBF8C',
  glass: '#F01E222A',
  glassBorder: '#FF6E7076',
  shadow: '#8C000000',
  scrim: '#99000000',
  icon: '#FFA2A8B4',
  placeholderFrom: '#FF1E222A',
  placeholderTo: '#FF2A2E37'
};

/**
 * v2.80：只保留纸墨（v5「墨栈」）一套 —— LIGHT / DARK 与四件套中性实色一字未改。
 * 全站取色/取材质只按 isDark 返回中性实色，不再有主题分发。
 */
export function palette(isDark: boolean): Palette {
  return isDark ? DARK : LIGHT;
}

/**
 * 墨栈新增语义 token（供组件精修；本版换肤不依赖它们，Palette 接口零变动）。
 * 色值均经 WCAG 逐项计算，浅 / 深分别取值。
 */
/** 结构性边界：浅 3.18:1 / 深 3.22:1，承担所有结构性发丝线 */
export function inkDividerStrong(isDark: boolean): string {
  return isDark ? '#FF6E7076' : '#FF817E7A';
}
/** 细线型琥珀（<8vp 竖轨 / 进度已播段 / 指示），保证 ≥4.5:1 */
export function inkSignalText(isDark: boolean): string {
  return isDark ? '#FFF3B044' : '#FF8F4B06';
}
/** 琥珀实底上的文字：只用墨色，浅深一致（7.57:1） */
export const INK_ON_SIGNAL: string = '#FF191713';
/** 反相墨块徽标上的文字 */
export function inkOnAccent(isDark: boolean): string {
  return isDark ? '#FF14161B' : '#FFF7F5F0';
}

/**
 * 材质档位（保留符号壳以兼容全站 @StorageProp('lightSense') 订阅）。
 * 去光化后四档返回同一组「实色」参数：无高光、无外发光、不透明、无氛围光，
 * 档位之间视觉差异为 0 —— 界面是不反光的纸墨表面，不再有玻璃质感可选。
 */
export interface LightSense {
  highlight: number;
  glowRadius: number;
  edge: number;
  glass: boolean;
  fill: number;
  ambience: number;
  depth: number;
}

/** 单一实色材质：忽略 level，四档恒等，避免「假控制」 */
export function lightSense(level: number): LightSense {
  return { highlight: 0, glowRadius: 0, edge: 1, glass: false, fill: 1, ambience: 0, depth: 1 };
}

/** 浮层填充：中性实色，无半透 rgba、无磨砂 */
export function glassFill(isDark: boolean, level: number): string {
  return isDark ? '#FF1E222A' : '#FFFDFCFA';
}

/**
 * 表面：去光化。返回两段同色的中性实色，linearGradient 渲染即一块平涂纸墨面，
 * 不再有上沿亮线 / 中段通透 / 下沿反光 / 青绿染色。保留 2 段以兼容调用点签名。
 */
export function glassSurface(isDark: boolean, level: number): Array<[ResourceColor, number]> {
  const c: string = isDark ? '#FF1E222A' : '#FFFDFCFA';
  return [[c, 0], [c, 1]];
}

/** 卡片兜底色：中性实色（万一渐变未被绘制，仍是纸墨面而非白板 / 青绿） */
export function glassCardBase(isDark: boolean): string {
  return isDark ? '#FF1E222A' : '#FFFDFCFA';
}

/** 下沿聚光：去光化后恒全透明，depthLayer 挂载点保留但不再产生亮带 */
export function glassDepth(isDark: boolean, level: number): Array<[ResourceColor, number]> {
  return [['#00FFFFFF', 0], ['#00FFFFFF', 1]];
}

/** 描边：1vp 等宽发丝线，不再「下比上厚」 */
export function glassEdgeWidth(level: number): EdgeWidths {
  return { top: 1, right: 1, bottom: 1, left: 1 };
}

/** 描边色：结构性中性边界，四边同色 */
export function glassEdgeColor(isDark: boolean, level: number): EdgeColors {
  const c: string = isDark ? '#FF6E7076' : '#FF817E7A';
  return { top: c, right: c, bottom: c, left: c };
}

/** 投影：中性紧投影（浅 r8/y2、深 r10/y4），去青绿外光晕、无离地浮起感 */
export function glassShadow(isDark: boolean, level: number): ShadowOptions {
  return {
    radius: isDark ? 10 : 8,
    color: isDark ? 'rgba(0,0,0,0.55)' : 'rgba(27,26,24,0.14)',
    offsetY: isDark ? 4 : 2
  };
}

/** 列表行轻投影：中性、贴地，避免十几行叠成一片 */
export function glassRowShadow(isDark: boolean): ShadowOptions {
  return {
    radius: 6,
    color: isDark ? 'rgba(0,0,0,0.34)' : 'rgba(27,26,24,0.10)',
    offsetY: 2
  };
}

/** 圆角阶梯 */
export interface RadiusScale {
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
  xxl: number;
  pill: number;
}

export const RADIUS: RadiusScale = {
  xs: 8,
  sm: 12,
  md: 16,
  lg: 20,
  xl: 26,
  xxl: 32,
  pill: 999
};

/** 间距阶梯 */
export interface SpaceScale {
  xxs: number;
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
  xxl: number;
  huge: number;
}

export const SPACE: SpaceScale = {
  xxs: 4,
  xs: 8,
  sm: 12,
  md: 16,
  lg: 20,
  xl: 24,
  xxl: 32,
  huge: 40
};

/** 字号阶梯 */
export interface FontScale {
  display: number;
  title: number;
  headline: number;
  body: number;
  callout: number;
  caption: number;
  micro: number;
}

export const FONT: FontScale = {
  display: 34,
  title: 26,
  headline: 19,
  body: 16,
  callout: 14,
  caption: 12,
  micro: 10
};

/** 页面左右安全边距 */
export const PAGE_PAD: number = 20;

/** 底部悬浮层占位（迷你播放条 + 胶囊标签栏） */
export const FLOAT_SPACE: number = 154;

/** 二级页面底部占位 */
export const PAGE_BOTTOM: number = 36;

/**
 * 二级页为全局迷你播放条额外留的高度（v4.0.38 起迷你条不再只属于一级页）。
 * 条本身约 57vp，这里取 64，含一点空隙，保证最后一行能滚到条上面。
 */
export const MINI_BAR_SPACE: number = 64;

export const TAB_ITEMS: string[] = ['首页', '发现', '设置'];

/** 主题模式 */
export enum ThemeMode {
  SYSTEM = 0,
  LIGHT = 1,
  DARK = 2
}

/** 持久化 key（统一前缀，便于迁移和清理） */
export class PrefKeys {
  static readonly SOURCES: string = 'v4_sources';
  static readonly ACTIVE_SOURCE: string = 'v4_active_source';
  static readonly SONG_CACHE: string = 'v4_song_cache';
  static readonly FAVORITES: string = 'v4_favorites';
  /** 收藏的「歌单」列表（平台歌单 / 榜单 / 专辑 / 歌手作品），与歌曲收藏分开存 */
  static readonly FAVORITE_SHEETS: string = 'v4_favorite_sheets';
  static readonly PLAYLISTS: string = 'v4_playlists';
  static readonly HISTORY: string = 'v4_history';
  static readonly SEARCH_HISTORY: string = 'v4_search_history';
  static readonly QUEUE: string = 'v4_queue';
  static readonly QUEUE_INDEX: string = 'v4_queue_index';
  static readonly LAST_SONG: string = 'v4_last_song';
  static readonly LAST_POS: string = 'v4_last_pos';
  static readonly QUALITY: string = 'v4_quality';
  static readonly PLAY_MODE: string = 'v4_play_mode';
  static readonly AUTO_PLAY: string = 'v4_auto_play';
  static readonly REMEMBER_POS: string = 'v4_remember_pos';
  static readonly IGNORE_INTERRUPT: string = 'v4_ignore_interrupt';
  static readonly THEME_MODE: string = 'v4_theme_mode';
  static readonly THEME_COLOR: string = 'v4_theme_color';
  static readonly LOCAL_SONGS: string = 'v4_local_songs';
  static readonly DOWNLOADS: string = 'v4_downloads';
  static readonly SHOW_TRANS: string = 'v4_show_trans';
  static readonly LYRIC_SIZE: string = 'v4_lyric_size';
  static readonly LYRIC_ALIGN: string = 'v4_lyric_align';
  static readonly SEARCH_PLATFORMS: string = 'v4_search_platforms';
  /** 搜索页选中的源：'all' 或平台 id */
  static readonly SEARCH_SOURCE: string = 'v4_search_source';
  /** 玻璃质感强度：0 关 / 1 柔和 / 2 标准 / 3 强 */
  static readonly LIGHT_SENSE: string = 'v4_light_sense';
  /** v2.56：光感四档移除的一次性提示是否已看过（旧 key 只读，不删，便于回滚） */
  static readonly LIGHT_SENSE_NOTICE: string = 'v4_light_sense_notice';
  static readonly DISCOVER_PLATFORM: string = 'v4_discover_platform';
  static readonly DOWNLOAD_DIR: string = 'v4_download_dir';
  /** 真实收听统计（小时桶 / 歌手累计 / 已知歌曲 / 每日新歌） */
  static readonly PLAY_STATS: string = 'v4_play_stats';
  /** 音源拿不到目标音质时，是否允许自动降级下载 */
  static readonly DOWNLOAD_DOWNGRADE: string = 'v4_download_downgrade';
  /** 启动时是否自动跑一轮轻量音源自检（默认关） */
  static readonly AUTO_CHECK_SOURCES: string = 'v4_auto_check_sources';
  /** 上次自动自检的时间戳，用来做「30 分钟内不重复跑」的节流 */
  static readonly AUTO_CHECK_AT: string = 'v4_auto_check_at';
  /** 是否记住「每首歌上次是哪个音源给的」，下次优先问它（默认开） */
  static readonly REMEMBER_SOURCE: string = 'v4_remember_source';
  /** 取链方式：'' = 跟随其它补位（旧行为）；'strict' = 只认首选音源 */
  static readonly SOURCE_MODE: string = 'v4_source_mode';
  /**
   * 下载前是否严格探测音源链接（默认关）。
   * 洛雪官方是「音源给什么链接就下什么」，不做二次探测；我们原先每次都发
   * Range 请求，中转 / 聚合接口常因防盗链、时效返回 403/404，本来能下的歌
   * 在探测这一步就被判死。关闭后改为「写盘后验文件头」，既不误伤也不虚标。
   */
  static readonly VERIFY_BEFORE_DOWNLOAD: string = 'v4_verify_before_download';
  /** 首选音源连续失败时，是否临时放开其它音源补位（默认开） */
  static readonly AUTO_FALLBACK_ON_FAILURE: string = 'v4_auto_fallback_on_failure';
  /**
   * 智能达标寻源（懒人模式，默认开）：只认目标音质、绝不降质；
   * 一个音源给不到就自动换下一个音源 / 平台 / 插件，全问过仍不达标就明确失败。
   */
  static readonly SMART_HUNT: string = 'v4_smart_hunt';
  /** 剩余多少秒开始预取下一首直链（默认开，弱网下提前跑完寻源） */
  static readonly PRELOAD_NEXT: string = 'v4_preload_next';
  static readonly FIRST_LAUNCH: string = 'v4_first_launch';
  /** v2.64 网易云本人账号：只存本机、不进备份。凭证 MUSIC_U / __csrf 等 */
  static readonly WY_COOKIE: string = 'v4_wy_cookie';
  static readonly WY_NICK: string = 'v4_wy_nick';
  static readonly WY_UID: string = 'v4_wy_uid';
  static readonly WY_AVATAR: string = 'v4_wy_avatar';
  /**
   * v2.65 歌单收藏 ↔ 网易云账号同步的中间态。
   * 故意不写进 Backup 的 STRING_KEYS / NUMBER_KEYS / BOOL_KEYS 白名单：
   * 换机恢复时不应把「待写云端的操作」「上次的云端快照」串到另一个账号上。
   * 这些键本身不含任何凭证明文，本地收藏正本仍在 FAVORITE_SHEETS（正常备份）。
   */
  static readonly WY_FAV_PENDING: string = 'v4_wy_fav_pending';
  static readonly WY_FAV_CLOUD: string = 'v4_wy_fav_cloud';
  static readonly WY_FAV_INIT: string = 'v4_wy_fav_init';
  static readonly WY_FAV_AT: string = 'v4_wy_fav_at';
}

/** 默认搜索热词（接口失败时兜底展示） */
/**
 * v2.74：这里原本是写死的 HOT_WORDS（晴天 / 稻香 / …），搜索页「大家都在搜」
 * 因此常年不变。已删除，改由 core/HotSearch.ets 拉网易云官方实时热搜；
 * 请求失败只给可重试提示，绝不再用固定词顶上（不造数）。
 */

/** 歌单分类（网易云为主，其它平台回退到热门） */
export const SHEET_CATS: string[] = ['全部', '华语', '流行', '摇滚', '民谣', '电子', '说唱', '古风', '轻音乐', '影视原声'];

/**
 * 音质档位全集（从高到低）。
 *
 * 洛雪官方协议只规定 4 档（128k / 320k / flac / flac24bit），但允许音源在
 * inited 的 sources[].qualitys 里自定义档位。主流第三方音源（ikun / 杰翔 /
 * 星海 / HelloWorld / 六音等）普遍声明 hires / atmos / atmos_plus / master，
 * 旧版全豆要还用别名 24bit。这里列全集供排序、比较与降级链使用；
 * UI 通过 qualityOptions() 只展示音源真正声明过的档位。
 */
export const QUALITY_ORDER: string[] = [
  'master', 'atmos_plus', 'atmos', 'hires', 'flac24bit', 'flac', '320k', '192k', '128k'
];

/** 没有音源或音源没声明档位时，UI 至少保留这几个基础档 */
export const BASE_QUALITY_ORDER: string[] = ['flac24bit', 'flac', '320k', '192k', '128k'];

/** 音源自定义档位 → 内部统一档位（大小写与别名） */
export function normalizeQuality(q: string): string {
  const s = (q ?? '').trim().toLowerCase();
  if (s === '24bit' || s === 'flac24' || s === 'flac24b') {
    return 'flac24bit';
  }
  if (s === 'hi-res' || s === 'hi_res' || s === 'hires24bit') {
    return 'hires';
  }
  if (s === 'atmosplus' || s === 'atmos+') {
    return 'atmos_plus';
  }
  if (s === 'dolby') {
    return 'atmos';
  }
  return s;
}

/**
 * 音质高低。用来做「拿到的到底够不够」的判断：
 * 请求无损就必须真的是无损，不能因为音源偷偷返回 128k 也当作无损。
 */
export function qualityRank(q: string): number {
  const n = normalizeQuality(q);
  if (n === 'master') {
    return 9;
  }
  if (n === 'atmos_plus') {
    return 8;
  }
  if (n === 'atmos') {
    return 7;
  }
  if (n === 'hires') {
    return 6;
  }
  if (n === 'flac24bit') {
    return 5;
  }
  if (n === 'flac') {
    return 4;
  }
  if (n === '320k') {
    return 3;
  }
  if (n === '192k') {
    return 2;
  }
  return 1;
}

/** 是不是无损 / 高规格档位（都要按 flac 级的真实性要求校验） */
export function isLossless(q: string): boolean {
  const n = normalizeQuality(q);
  return n === 'flac' || n === 'flac24bit' || n === 'hires' ||
    n === 'atmos' || n === 'atmos_plus' || n === 'master';
}

export function qualityLabel(q: string): string {
  const n = normalizeQuality(q);
  if (n === 'master') {
    return '母带';
  }
  if (n === 'atmos_plus') {
    return '全景声+';
  }
  if (n === 'atmos') {
    return '全景声';
  }
  if (n === 'hires') {
    return 'Hi-Res+';
  }
  if (n === 'flac24bit') {
    return 'Hi-Res';
  }
  if (n === 'flac') {
    return 'FLAC';
  }
  if (n === '320k') {
    return '320K';
  }
  if (n === '192k') {
    return '192K';
  }
  return '128K';
}

/**
 * UI 音质选项：基础 5 档常驻，扩展档（母带 / 全景声 / Hi-Res+）只在
 * 音源 inited 里声明过才出现（洛雪官方客户端同款机制）。
 * declared 里可同时塞当前已选档位，避免切换音源后旧设置从列表里消失。
 */
export function qualityOptions(declared: string[]): string[] {
  const all: string[] = [];
  for (const q of declared) {
    all.push(q);
  }
  for (const q of BASE_QUALITY_ORDER) {
    all.push(q);
  }
  const norm: string[] = [];
  for (const q of all) {
    const n = normalizeQuality(q);
    if (QUALITY_ORDER.indexOf(n) >= 0 && norm.indexOf(n) < 0) {
      norm.push(n);
    }
  }
  const out: string[] = [];
  for (const q of QUALITY_ORDER) {
    if (norm.indexOf(q) >= 0) {
      out.push(q);
    }
  }
  return out;
}
