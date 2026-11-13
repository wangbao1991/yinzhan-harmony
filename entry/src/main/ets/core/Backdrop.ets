import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { CoverRepo } from './CoverRepo';

/**
 * 播放页背景图仓库：把封面「下载 → 按屏幕尺寸裁成 cover → 存成本地 JPEG」。
 *
 * 为什么要多这一步：
 * 直接把网络封面丢给整屏背景层，真机上各种画不出来（子节点尺寸推导、网络图加载策略都可能踩）。
 * 落成本地文件后，背景只是一次本地读图：尺寸等于屏幕、路径是 `file://`，
 * 既不需要放大、也不需要联网，是这条链上变量最少的一步。
 *
 * 缓存：按「歌曲 key + 目标尺寸」存一张，命中直接返回，切回来不重复下载。
 */
export class Backdrop {
  private static instance: Backdrop = new Backdrop();
  static get(): Backdrop {
    return Backdrop.instance;
  }

  private dir: string = '';
  private cache: Map<string, string> = new Map<string, string>();
  private busy: Set<string> = new Set<string>();

  /** 只需调一次；重复调用无副作用 */
  init(context: common.UIAbilityContext): void {
    if (this.dir.length > 0) {
      return;
    }
    this.dir = context.filesDir + '/bg';
    try {
      fileIo.mkdirSync(this.dir);
    } catch (e) {
      // 目录已存在会抛，忽略
    }
  }

  private pathOf(key: string): string {
    return this.dir + '/' + key + '.jpg';
  }

  /** 已经生成过的直接给路径（同步，用于首帧就能显示） */
  cached(key: string): string {
    const hit = this.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    if (this.dir.length === 0) {
      return '';
    }
    const path = this.pathOf(key);
    try {
      if (fileIo.accessSync(path)) {
        const uri = 'file://' + path;
        this.trim();
        this.cache.set(key, uri);
        return uri;
      }
    } catch (e) {
      return '';
    }
    return '';
  }

  private trim(): void {
    if (this.cache.size <= 40) {
      return;
    }
    this.cache.clear();
  }

  /** 拉一次字节；非 200 / 空包 / 异常都返回 null，交给调用方换形态重试 */
  private async fetch(client: http.HttpRequest, url: string): Promise<ArrayBuffer | null> {
    try {
      const resp = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: true,
        connectTimeout: 8000,
        readTimeout: 15000
      } as http.HttpRequestOptions);
      if (resp.responseCode !== 200) {
        return null;
      }
      const buf = resp.result as ArrayBuffer;
      if (buf === undefined || buf.byteLength === 0) {
        return null;
      }
      return buf;
    } catch (e) {
      console.warn('[bg] 封面下载失败: ' + String(e));
      return null;
    }
  }

  /**
   * 下载并按 `w × h`（物理像素）裁好落盘。
   * 失败返回空串，调用方继续用原来的兜底。
   */
  async build(key: string, url: string, w: number, h: number): Promise<string> {
    if (url.length === 0 || w <= 0 || h <= 0) {
      return '';
    }
    const hit = this.cached(key);
    if (hit.length > 0) {
      return hit;
    }
    if (this.busy.has(key) || this.dir.length === 0) {
      return '';
    }
    this.busy.add(key);
    const client = http.createHttp();
    try {
      // 原地址拿不到就换一种形态再试一次（http↔https / 尺寸占位替换）。
      // `Cover` 组件一直有这个回退，所以卡片能显示；背景之前没做，坏图那几首就只能黑着。
      let buf = await this.fetch(client, url);
      if (buf === null) {
        const alt = CoverRepo.alternate(url);
        if (alt.length > 0 && alt !== url) {
          buf = await this.fetch(client, alt);
        }
      }
      if (buf === null) {
        return '';
      }
      const source = image.createImageSource(buf);
      const info = await source.getImageInfo();
      const sw = info.size.width;
      const sh = info.size.height;
      if (sw <= 0 || sh <= 0) {
        await source.release();
        return '';
      }
      // cover：等比放大到刚好盖住 w×h，取中间那块。
      // 1:1 封面铺 9:19.5 的屏，横向只能留下 1/3，画面必然是「放大后的一小块局部」，
      // 直接铺上去会显得又大又硬。所以这里先按半分辨率解码，再做一次高斯模糊——
      // 背景只保留色块和轮廓，作为氛围层，比例感也就没了。
      const scale = Math.max(w / sw, h / sh);
      const cw = Math.max(1, Math.min(sw, Math.floor(w / scale)));
      const ch = Math.max(1, Math.min(sh, Math.floor(h / scale)));
      const halfW = Math.max(1, Math.round(w / 2));
      const halfH = Math.max(1, Math.round(h / 2));
      const options: image.DecodingOptions = {
        desiredRegion: {
          size: { width: cw, height: ch },
          x: Math.floor((sw - cw) / 2),
          y: Math.floor((sh - ch) / 2)
        },
        desiredSize: { width: halfW, height: halfH }
      };
      const pixelMap = await source.createPixelMap(options);
      await source.release();

      // 高斯模糊：半径按图宽比例给，换分辨率也不会跑偏
      let out: image.PixelMap = pixelMap;
      try {
        const filter = effectKit.createEffect(pixelMap);
        if (filter != null) {
          // 0.028：屏幕宽约 1300px 时对应 ~37px，够盖掉「放大 2.8 倍」的锐利感，又还留得住轮廓
          await filter.blur(Math.max(6, Math.round(halfW * 0.028)));
          const blurred = await filter.getEffectPixelMap();
          if (blurred != null) {
            out = blurred;
          }
        }
      } catch (e) {
        console.warn('[bg] 背景模糊失败，退回清晰图: ' + String(e));
      }

      const packer = image.createImagePacker();
      const path = this.pathOf(key);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      await packer.packToFile(out, file.fd, { format: 'image/jpeg', quality: 90 });
      fileIo.closeSync(file);
      await packer.release();
      if (out !== pixelMap) {
        await out.release();
      }
      await pixelMap.release();

      const uri = 'file://' + path;
      this.trim();
      this.cache.set(key, uri);
      return uri;
    } catch (e) {
      console.warn('[bg] 生成背景图失败: ' + String(e));
      return '';
    } finally {
      client.destroy();
      this.busy.delete(key);
    }
  }
}
