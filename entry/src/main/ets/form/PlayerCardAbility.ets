import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 桌面服务卡片的数据端（v2.23）。
 *
 * 工程里 `form_config.json`、`string.json` 的 PlayerCard_* 资源早就写好了，
 * 但 module.json5 一直没注册 FormExtensionAbility、卡片页面也不存在，
 * 属于「配置在、实现缺」的半成品。本版把两端补齐。
 *
 * 数据链路克制在零侵入范围：卡片进程用 getPreferencesSync 直接读应用沙箱里
 * 同一份 `yinzhan_v1` 偏好，取 `v4_last_song`（Player 每次切歌写的是完整
 * SongInfo JSON）里的歌名与歌手。不修改 Player、不注册跨进程监听、不引三方依赖。
 * 刷新靠系统按 form_config.json 的 updateDuration 触发 onUpdateForm，
 * 因此卡片显示的是「最近一次落盘的最近播放」，不是伪造的实时播放状态。
 */

interface CardSong {
  name?: string;
  singer?: string;
}

interface CardData {
  songName: string;
  singer: string;
  hint: string;
}

export default class PlayerCardAbility extends FormExtensionAbility {
  private static readonly PREF_NAME: string = 'yinzhan_v1';
  private static readonly LAST_SONG: string = 'v4_last_song';

  onAddForm(want: Want): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData(this.readData());
  }

  /** 系统按 updateDuration 定时触发：重新读一次落盘数据并推给指定卡片 */
  onUpdateForm(formId: string): void {
    formProvider.updateForm(formId, formBindingData.createFormBindingData(this.readData()))
      .catch((): void => {
        console.warn('[PlayerCard] 定时刷新失败');
      });
  }

  /** 卡片上的 router 动作由系统直接拉起 EntryAbility，这里只留日志 */
  onFormEvent(formId: string, message: string): void {
    console.info('[PlayerCard] 卡片事件 ' + message);
  }

  onRemoveForm(formId: string): void {
    console.info('[PlayerCard] 卡片移除 ' + formId);
  }

  private readData(): CardData {
    try {
      const pref = preferences.getPreferencesSync(this.context,
        { name: PlayerCardAbility.PREF_NAME });
      const raw = pref.getSync(PlayerCardAbility.LAST_SONG, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const song = JSON.parse(raw) as CardSong;
        const name = typeof song.name === 'string' ? song.name : '';
        const singer = typeof song.singer === 'string' ? song.singer : '';
        if (name.length > 0) {
          return { songName: name, singer: singer.length > 0 ? singer : '未知歌手', hint: '最近播放' };
        }
      }
    } catch (e) {
      // 卡片进程读不到偏好时退回引导文案，不抛异常打断桌面
    }
    return { songName: '音栈', singer: '打开应用开始听歌', hint: '未在播放' };
  }
}
