import { SongInfo, SheetInfo } from '../common/Models';
import { WyRecommend } from './WyRecommend';
import { WyAccount } from './WyAccount';

/**
 * 网易云账号推荐数据的唯一数据源（单例，v2.71）。
 *
 * 用户要求把账号页的「每日推荐 / 为你推荐歌单」搬到首页，并要像发现页一样是
 * 实时状态，而不是写死固定内容。若首页与账号页各自调 WyRecommend，同一份画像
 * 会拉两遍、两处状态还对不上；这里收成一份：
 *  - 只有本类持有歌曲 / 歌单 / 在途标志 / 最近成功时间 / 提示语；
 *  - 两处 UI 都订阅 wyRecVersion，版本一变就重读同一份快照（铁律 9：一级页
 *    常驻不销毁，跨页刷新必须走 AppStorage + @StorageProp/@Watch）；
 *  - refresh() 并发发两个 weapi 请求，带在途锁，不重复打云端；
 *  - 未登录 / 退出登录一律清空，绝不拿游客数据或假数据填板块（铁律 2）；
 *  - 失败保留上一次成功的数据并给明确提示，不假装刷新成功、不清空本地。
 *
 * 触发点：首页 aboutToAppear / 回前台 / 登录变化 / 下拉刷新，账号页进页与
 * 「刷新」。推荐内容随账号画像变化，不落本机存档（落盘只会展示过期画像）。
 */
export class WyRecommendHub {
  private static instance: WyRecommendHub = new WyRecommendHub();

  static get(): WyRecommendHub {
    return WyRecommendHub.instance;
  }

  private songList: SongInfo[] = [];
  private sheetList: SheetInfo[] = [];
  private loadingFlag: boolean = false;
  private inFlight: boolean = false;
  private at: number = 0;
  private hintText: string = '';
  private versionNum: number = 0;

  songs(): SongInfo[] {
    return this.songList;
  }

  sheets(): SheetInfo[] {
    return this.sheetList;
  }

  isLoading(): boolean {
    return this.loadingFlag;
  }

  lastAt(): number {
    return this.at;
  }

  hint(): string {
    return this.hintText;
  }

  /** 只广播版本号：数据本体留在单例里，避免把 30 首歌塞进 AppStorage */
  private broadcast(): void {
    this.versionNum += 1;
    AppStorage.setOrCreate('wyRecVersion', this.versionNum);
  }

  /**
   * 重新拉取本人账号推荐。并发启动两个请求后依次 await（工程既有写法），
   * 在途锁挡住回前台 / 下拉 / 进页叠加出来的重复请求。
   */
  async refresh(): Promise<void> {
    if (this.inFlight) {
      return;
    }
    if (!WyAccount.get().isLoggedIn()) {
      this.songList = [];
      this.sheetList = [];
      this.at = 0;
      this.hintText = '';
      this.loadingFlag = false;
      this.broadcast();
      return;
    }
    this.inFlight = true;
    this.loadingFlag = true;
    this.hintText = '';
    this.broadcast();
    const pSongs = WyRecommend.dailySongs();
    const pSheets = WyRecommend.dailySheets();
    try {
      const songs = await pSongs;
      const sheets = await pSheets;
      this.songList = songs;
      this.sheetList = sheets;
      this.at = Date.now();
      if (songs.length === 0 && sheets.length === 0) {
        this.hintText = '暂时没取到推荐，可能是登录状态已过期，可退出后重新登录';
      }
    } catch (e) {
      // 失败不动旧数据，只给可重试提示；下一次成功会把它清掉
      this.hintText = '推荐更新失败，点此重试';
    } finally {
      this.loadingFlag = false;
      this.inFlight = false;
      this.broadcast();
    }
  }
}
