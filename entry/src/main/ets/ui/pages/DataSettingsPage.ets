import { common } from '@kit.AbilityKit';
import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow,
  DOWNLOAD_CONCURRENCY_MIN, DOWNLOAD_CONCURRENCY_MAX, DOWNLOAD_CONCURRENCY_DEFAULT
} from '../../common/Constants';
import { App } from '../../core/App';
import { Settings } from '../../core/Settings';
import { Backup } from '../../core/Backup';
import { ImmersiveBar } from '../Common';
import { SettingArrowRow, applyThemeMode } from '../SettingsCommon';

function formatSize(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes >= 1073741824) {
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return bytes.toString() + ' B';
}

/**
 * 数据（二级页）：本地数据备份 / 恢复 + 下载设置 + 备份范围说明。
 *
 * v2.63：从设置主页的「数据」分组整体搬来，主页只留一个「数据管理」入口。
 * v1.0 第四次返工：把下载管理页红圈标记的三块（统计卡片 / 同时下载步进器 /
 * 听够 2/3 自动下载开关）整体搬到这里。下载管理页只保留任务列表与队列操作，
 * 设置类内容集中到数据页，避免一边下歌一边被大块设置卡挤占列表空间。
 *
 * 「已完成」改叫「已下载」：2026-11-16 起下载不再登记进本地音乐，
 * 数字来自 Downloader.doneCount()（队列里的 done 记录），占用空间由这些记录的
 * 实际字节数累加，不再与「本地音乐」混为一谈。
 *
 * 恢复后的刷新分两路，都不依赖本页组件树：
 *   - 主题：与「外观」页共用 applyThemeMode 单一实现，切系统 ColorMode 并广播 isDark；
 *   - 收藏 / 统计 / 派生偏好（含 discoverPlatform）：Backup.refreshAfterRestore()
 *     统一 reload 单例并写 AppStorage，设置主页通过 @Watch 订阅广播后自行 reload。
 *
 * 返回链与外观页一致：无页内弹层，顶栏与系统返回都走 App.consumeBack(null)。
 */
@Component
export struct DataSettingsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  /** 下载队列状态变化（入队 / 开始 / 暂停 / 完成 / 清理）时刷新统计与档位 */
  @StorageProp('downloadVersion') @Watch('onDownloadChanged') downloadVersion: number = 0;
  @State active: number = 0;
  @State localCount: number = 0;
  @State totalBytes: number = 0;
  @State dirName: string = '';
  @State concurrency: number = DOWNLOAD_CONCURRENCY_DEFAULT;
  @State autoDownload: boolean = false;
  private settings: Settings = Settings.get();

  aboutToAppear(): void {
    this.refresh();
    this.autoDownload = this.settings.autoDownloadOnPlay();
  }

  onDownloadChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    const downloads = App.get().downloads;
    this.active = downloads.activeCount();
    this.localCount = downloads.doneCount();
    this.totalBytes = downloads.totalBytes();
    this.dirName = downloads.getDirName();
    this.concurrency = App.get().downloads.concurrency();
  }

  private applyConcurrency(n: number): void {
    if (n < DOWNLOAD_CONCURRENCY_MIN || n > DOWNLOAD_CONCURRENCY_MAX) {
      return;
    }
    App.get().downloads.setConcurrency(n);
    this.refresh();
    App.get().toast('已设为同时下载 ' + this.concurrency.toString() + ' 首');
  }

  /**
   * v2.22 备份：交给系统保存面板，用户只选目录，不联网、不落额外权限。
   * 取消选择时 Backup 返回空串，不弹提示——这是用户主动取消，不是失败。
   */
  private async doBackup(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const msg = await Backup.exportTo(context);
      if (msg.length > 0) {
        App.get().toast(msg);
      }
    } catch (e) {
      App.get().toast('备份失败：' + (e instanceof Error ? e.message : String(e)));
    }
  }

  /** v2.22 恢复：成功后主题与派生偏好的刷新交给 Backup + 各页 AppStorage 订阅 */
  private async doRestore(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const result = await Backup.restoreFrom(context);
      if (result.text.length === 0) {
        return;
      }
      App.get().toast(result.text);
      if (result.ok) {
        // 主题应用与「外观」页 / 设置主页共用同一实现，避免两处各写一份导致恢复后不生效
        applyThemeMode(this.settings.themeMode(), context);
        this.refresh();
      }
    } catch (e) {
      App.get().toast('恢复失败：' + (e instanceof Error ? e.message : String(e)));
    }
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(FONT.caption)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.p().text3)
      .width('100%')
      .padding({ left: 14, top: 6 })
  }

  /** 从下载管理页搬来：进行中 / 已下载 / 占用空间 + 保存目录与检测 */
  @Builder
  statCard() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text(this.active.toString())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().primary)
          Text('进行中').fontSize(FONT.micro).fontColor(this.p().text3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 3 }) {
          Text(this.localCount.toString())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().success)
          Text('已下载').fontSize(FONT.micro).fontColor(this.p().text3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 3 }) {
          Text(formatSize(this.totalBytes))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
          Text('占用空间').fontSize(FONT.micro).fontColor(this.p().text3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider().color(this.p().line)

      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(16).fontColor([this.p().text2])
        Column({ space: 2 }) {
          Text('保存目录')
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
          Text(this.dirName)
            .fontSize(FONT.callout)
            .fontColor(this.p().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('检测')
          .fontSize(FONT.callout)
          .fontColor(this.p().primary)
          .padding({ left: 8, right: 4 })
          .onClick(() => {
            App.get().downloads.refreshDir().then((tip: string) => {
              this.refresh();
              App.get().toast(tip);
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  /** 从下载管理页搬来：并行下载档位，一行式「− 数字 +」 */
  @Builder
  concurrencyCard() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text('同时下载')
          .fontSize(FONT.callout)
          .fontColor(this.p().text)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 6 }) {
        Text('-')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.concurrency > DOWNLOAD_CONCURRENCY_MIN ? this.p().primary : this.p().text3)
          .padding({ left: 9, right: 9, top: 3, bottom: 5 })
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.pill)
          .opacity(this.concurrency > DOWNLOAD_CONCURRENCY_MIN ? 1 : 0.4)
          .onClick(() => {
            this.applyConcurrency(this.concurrency - 1);
          })

        Text(this.concurrency.toString() + ' 首')
          .fontSize(FONT.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().primary)
          .width(42)
          .textAlign(TextAlign.Center)

        Text('+')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.concurrency < DOWNLOAD_CONCURRENCY_MAX ? this.p().primary : this.p().text3)
          .padding({ left: 9, right: 9, top: 3, bottom: 5 })
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.pill)
          .opacity(this.concurrency < DOWNLOAD_CONCURRENCY_MAX ? 1 : 0.4)
          .onClick(() => {
            this.applyConcurrency(this.concurrency + 1);
          })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 10, top: 9, bottom: 9 })
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  /** 从下载管理页搬来：听够 2/3 自动下载开关，默认关，落盘在 Settings */
  @Builder
  autoDownloadCard() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text('听够 2/3 自动下载')
          .fontSize(FONT.callout)
          .fontColor(this.p().text)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.autoDownload })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.autoDownload = on;
          this.settings.setAutoDownloadOnPlay(on);
          App.get().toast(on ? '已开启：听够 2/3 自动下载' : '已关闭自动下载');
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 10, top: 9, bottom: 9 })
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column({ space: 16 }) {
            this.sectionTitle('下载设置')
            this.statCard()
            this.concurrencyCard()
            this.autoDownloadCard()

            this.sectionTitle('备份与恢复')
            Column() {
              SettingArrowRow({
                icon: $r('sys.symbol.arrow_up_circle'),
                title: '备份我的数据',
                value: '',
                onTap: () => {
                  this.doBackup();
                }
              })
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              SettingArrowRow({
                icon: $r('sys.symbol.arrow_down_circle'),
                title: '从备份恢复',
                value: '',
                onTap: () => {
                  this.doRestore();
                }
              })
            }
            .width('100%')
            .borderRadius(RADIUS.lg)
            .backgroundColor(glassCardBase(this.isDark))
            .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
            .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
            .shadow(glassShadow(this.isDark, this.lightLevel))
            .clip(true)

            Row().height(FLOAT_SPACE)
          }
          .width('100%')
          .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 52 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor(this.p().bg)

        ImmersiveBar({
          title: '数据管理',
          subtitle: '下载与备份',
          onBack: (): void => {
            App.get().back(null);
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed(() => App.get().consumeBack(null))
  }
}
