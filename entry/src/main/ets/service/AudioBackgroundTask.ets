import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 音频长时任务：应用退到后台（切桌面 / 锁屏 / 切到其他应用）后保持进程存活，
 * 让 AVPlayer 继续出声，并保住播控中心会话。
 *
 * 需要 module.json5 中声明：
 *   "backgroundModes": ["audioPlayback"]
 *   "requestPermissions": [{ "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" }]
 */
export class AudioBackgroundTask {
  private running: boolean = false;
  private starting: boolean = false;

  isRunning(): boolean {
    return this.running;
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running || this.starting) {
      return;
    }
    this.starting = true;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.running = true;
      console.info('[LX] 音频长时任务已启动');
    } catch (e) {
      const err = e as BusinessError;
      console.error('[LX] 音频长时任务启动失败: ' + err.code + ' ' + err.message);
    } finally {
      this.starting = false;
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      console.info('[LX] 音频长时任务已停止');
    } catch (e) {
      const err = e as BusinessError;
      console.error('[LX] 音频长时任务停止失败: ' + err.code + ' ' + err.message);
    }
  }
}
