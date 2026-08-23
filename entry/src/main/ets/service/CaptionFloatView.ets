import { floatView, window } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../util/Logger';

export class CaptionFloatView {
  private static instance: CaptionFloatView | undefined = undefined;
  private controller?: floatView.FloatViewController;
  private isRunning: boolean = false;

  private storage: LocalStorage = new LocalStorage({
    original: '',
    translation: '等待语音输入...'
  });

  static getInstance(): CaptionFloatView {
    if (!CaptionFloatView.instance) {
      CaptionFloatView.instance = new CaptionFloatView();
    }
    return CaptionFloatView.instance;
  }

  async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const permissions: Permissions[] = ['ohos.permission.FLOAT_VIEW'];
      const result = await manager.requestPermissionsFromUser(context, permissions);
      Log.info(`[CaptionFloatView] permission result: ${JSON.stringify(result)}`);
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        return true;
      }
      Log.error('[CaptionFloatView] FLOAT_VIEW permission denied or not in ACL');
      return false;
    } catch (err) {
      const e = err as BusinessError;
      Log.error(`[CaptionFloatView] requestPermission failed: ${e.code} ${e.message}`);
      return false;
    }
  }

  async start(context: common.UIAbilityContext): Promise<boolean> {
    if (this.isRunning && this.controller) {
      Log.info('[CaptionFloatView] Already running');
      return true;
    }

    try {
      if (typeof floatView.isFloatViewEnabled === 'function') {
        const supported = floatView.isFloatViewEnabled();
        if (!supported) {
          Log.error('[CaptionFloatView] isFloatViewEnabled returned false (device/system unsupported)');
          throw new Error('设备系统未开启或不支持 FloatView');
        }
      }

      const granted = await this.requestPermission(context);
      if (!granted) {
        throw new Error('未获 ohos.permission.FLOAT_VIEW 权限（需检查 ACL Profile）');
      }

      let limits: floatView.FloatViewLimits | undefined = undefined;
      if (typeof floatView.getFloatViewLimits === 'function') {
        limits = floatView.getFloatViewLimits(floatView.FloatViewTemplateType.HORIZONTAL_BAR);
        Log.info(`[CaptionFloatView] limits=${JSON.stringify(limits)}`);
      }

      const config: floatView.FloatViewConfiguration = {
        context: context,
        templateType: floatView.FloatViewTemplateType.HORIZONTAL_BAR,
        isConfirmOnClose: false
      };

      this.controller = await floatView.create(config);
      Log.info('[CaptionFloatView] controller created');

      this.controller.onStateChange((info: floatView.FloatViewStateChangeInfo) => {
        Log.info(`[CaptionFloatView] state=${JSON.stringify(info)}`);
      });

      this.controller.onRectChange((info: floatView.FloatViewRectChangeInfo) => {
        Log.info(`[CaptionFloatView] rect=${JSON.stringify(info)}`);
      });

      await this.controller.setUIContext('pages/CaptionFloat', this.storage);

      const targetWidth = limits ? Math.min(limits.maxSize.width, Math.max(limits.minSize.width, 900)) : 900;
      const targetHeight = limits ? Math.min(limits.maxSize.height, Math.max(limits.minSize.height, 160)) : 160;

      const size: window.Size = {
        width: targetWidth,
        height: targetHeight
      };

      await this.controller.switchTemplate({
        templateType: floatView.FloatViewTemplateType.HORIZONTAL_BAR,
        size: size
      });

      await this.controller.start();
      this.isRunning = true;
      Log.info('[CaptionFloatView] FloatView started successfully!');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      const msg: string = e.message ?? (err instanceof Error ? err.message : JSON.stringify(err));
      Log.error(`[CaptionFloatView] start failed: ${e.code ?? ''} ${msg}`);
      throw new Error(msg);
    }
  }

  update(original: string, translation: string): void {
    this.storage.setOrCreate('original', original);
    this.storage.setOrCreate('translation', translation);
  }

  updateOriginal(original: string): void {
    this.storage.setOrCreate('original', original);
  }

  updateTranslation(translation: string): void {
    this.storage.setOrCreate('translation', translation);
  }

  async stop(): Promise<void> {
    if (!this.controller) {
      this.isRunning = false;
      return;
    }
    try {
      await this.controller.stop();
      this.isRunning = false;
      Log.info('[CaptionFloatView] stop requested');
    } catch (err) {
      const e = err as BusinessError;
      Log.error(`[CaptionFloatView] stop failed: ${e.code} ${e.message}`);
    }
  }
}
