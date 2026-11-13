import { common } from '@kit.AbilityKit';
import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { App } from '../../core/App';
import { Settings } from '../../core/Settings';
import { Backup } from '../../core/Backup';
import { ImmersiveBar } from '../Common';
import { SettingArrowRow, applyThemeMode } from '../SettingsCommon';

/**
 * 数据（二级页）：本地数据备份 / 恢复 + 备份范围说明。
 *
 * v2.63：从设置主页的「数据」分组整体搬来，主页只留一个「数据管理」入口，
 * 与「播放设置」「外观」两个二级页形态一致。备份 / 恢复走系统保存 / 选择
 * 面板（DocumentViewPicker），不需要页内 bindSheet。
 *
 * 恢复后的刷新分两路，都不依赖本页组件树：
 *   - 主题：与「外观」页共用 applyThemeMode 单一实现，切系统 ColorMode 并广播 isDark；
 *   - 收藏 / 统计 / 派生偏好（含 discoverPlatform）：Backup.refreshAfterRestore()
 *     统一 reload 单例并写 AppStorage，设置主页通过 @Watch 订阅广播后自行 reload。
 * 所以本页恢复成功后无需也不该在这里刷别的页面的状态。
 *
 * 返回链与外观页一致：无页内弹层，顶栏与系统返回都走 App.consumeBack(null)。
 */
@Component
export struct DataSettingsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  private settings: Settings = Settings.get();

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


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column({ space: 16 }) {
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
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              Text('包含收藏、歌单收藏、最近播放、搜索历史、收听统计、全部设置与音源脚本（含脚本正文，恢复后自动重新导入）；本地音乐与下载文件请用各自入口单独导出')
                .fontSize(FONT.micro)
                .fontColor(this.p().text3)
                .lineHeight(17)
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 14 })
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
          subtitle: '备份与恢复',
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
