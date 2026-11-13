import {
  palette, Palette, RADIUS, FONT,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../common/Constants';
import { SongInfo, ArtistInfo, emptySong } from '../common/Models';
import { platformName } from '../common/Platform';
import { App } from '../core/App';
import { Library } from '../core/Library';
import { CoverRepo } from '../core/CoverRepo';
import { Cover, IconTap } from './Common';

/**
 * 歌曲操作面板（半模态）。
 *
 * 把「收藏 / 下载 / 查看歌手 / 从歌单移除」收在一处，所有页面长按或点「…」
 * 都弹它，行为完全一致。插队播放与归入自建歌单这两项及配套选择器已下线。
 * 音源取链、换源这类重活不放在这里，留在播放页。
 */
@Component
export struct SongMenu {
  @Prop song: SongInfo = emptySong();
  /** 来源场景：favorites / playlist / history / download，决定是否出现「移除」 */
  @Prop kind: string = '';
  @Prop playlistId: string = '';
  /**
   * 隐藏「下载到本地」。
   * 播放页底部已经有一个下载按钮，同一屏再给一个入口就是重复——
   * 两个都调 downloads.enqueue，连提示文案都一样。
   */
  @Prop hideDownload: boolean = false;
  /**
   * 隐藏「收藏到我喜欢」。
   * 播放页底排已经有一级「收藏」按钮，同一屏的「更多」里再给一项就是重复入口——
   * 更要命的是两个入口的状态不同步时，用户会以为其中一个坏了。
   */
  @Prop hideFavorite: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @State favorite: boolean = false;
  onDone: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.favorite = Library.get().isFavorite(this.song);
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private close(): void {
    this.onDone();
  }

  private toggleFavorite(): void {
    const added = Library.get().toggleFavorite(this.song);
    this.favorite = added;
    App.get().toast(added ? '已加入我喜欢的音乐' : '已取消收藏');
    this.close();
  }

  private download(): void {
    if (App.get().hasDownload(this.song)) {
      App.get().toast('这首歌已经在本地了');
      this.close();
      return;
    }
    App.get().downloads.enqueue(this.song);
    App.get().toast('已加入下载队列');
    this.close();
  }

  private openArtist(): void {
    const artist: ArtistInfo = {
      id: '',
      name: this.song.singer,
      avatar: '',
      platform: this.song.source,
      subtitle: platformName(this.song.source)
    };
    this.close();
    App.get().openArtist(artist);
  }

  private removeFromSheet(): void {
    if (this.kind === 'favorites') {
      Library.get().removeFavorite(this.song);
      App.get().toast('已从我喜欢中移除');
    } else if (this.kind === 'playlist' && this.playlistId.length > 0) {
      Library.get().removeFromPlaylist(this.playlistId, this.song);
      App.get().toast('已从歌单移除');
    }
    this.close();
  }

  @Builder
  actionRow(icon: Resource, label: string, danger: boolean, action: () => void) {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([danger ? this.p().danger : this.p().text2])
      }
      .width(34)
      .height(34)
      .borderRadius(12)
      .backgroundColor(this.p().cardAlt)

      Text(label)
        .fontSize(FONT.body)
        .fontColor(danger ? this.p().danger : this.p().text)
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      action();
    })
  }

  @Builder
  header() {
    Row({ space: 12 }) {
      Cover({ uri: this.song.cover, songId: CoverRepo.keyOf(this.song), side: 52, radius: 14 })
      Column({ space: 4 }) {
        Text(this.song.name.length > 0 ? this.song.name : '未知歌曲')
          .fontSize(FONT.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((this.song.singer.length > 0 ? this.song.singer : '未知歌手') +
          (this.song.album.length > 0 ? ' · ' + this.song.album : ''))
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      IconTap({
        icon: $r('sys.symbol.xmark'),
        iconSize: 16,
        color: this.p().text3,
        paddingSize: 6,
        onTap: () => {
          this.close();
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 6, bottom: 10 })
  }

  @Builder
  actions() {
    Column() {
      this.header()
      Divider().color(this.p().line).margin({ left: 16, right: 16 })
      // 「我喜欢」列表里，底部已经有「从我喜欢中移除」，这里再放一个「取消收藏」
      // 就是同一屏两个按钮做同一件事，只保留红色的移除项。
      // hideFavorite：播放页底排有独立的一级收藏按钮，这里不再重复。
      if (!this.hideFavorite && this.kind !== 'favorites') {
        this.actionRow(this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
          this.favorite ? '取消收藏' : '收藏到我喜欢', false, () => {
            this.toggleFavorite();
          })
      }
      // 本地音乐本来就是本地文件，平台歌也已下载完的不该再出现「下载」：
      // 点了只会弹「已经在本地了」，等于把内部状态泄给用户看。
      // hideDownload：播放页底部已经有一个下载按钮，同一屏不再给第二个入口。
      if (!this.hideDownload && this.song.source !== 'local' && !App.get().hasDownload(this.song)) {
        this.actionRow($r('sys.symbol.arrow_down_circle'), '下载到本地', false, () => {
          this.download();
        })
      }
      if (this.song.singer.length > 0 && this.song.source !== 'local') {
        this.actionRow($r('sys.symbol.person'), '查看歌手', false, () => {
          this.openArtist();
        })
      }
      if (this.kind === 'favorites' || (this.kind === 'playlist' && this.playlistId.length > 0)) {
        this.actionRow($r('sys.symbol.trash'), this.kind === 'favorites' ? '从我喜欢中移除' : '从歌单中移除',
          true, () => {
            this.removeFromSheet();
          })
      }
      Row()
        .height(24)
    }
    .width('100%')
  }


  build() {
    Column() {
      this.actions()
    }
    .width('100%')
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }
}
