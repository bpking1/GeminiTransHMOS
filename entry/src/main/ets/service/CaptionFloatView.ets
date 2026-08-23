import { floatView, window } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PiPManager } from './PiPManager';
import { Log } from '../util/Logger';

export class FloatWindowSize implements window.Size {
  width: number = 900;
  height: number = 112;
  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

export class CaptionFloatConfig implements floatView.FloatViewConfiguration {
  context: common.UIAbilityContext;
  templateType: floatView.FloatViewTemplateType = floatView.FloatViewTemplateType.HORIZONTAL_BAR;
  isConfirmOnClose: boolean = false;
  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }
}

export class CaptionFloatTemplateProperty implements floatView.TemplateProperty {
  templateType: floatView.FloatViewTemplateType = floatView.FloatViewTemplateType.HORIZONTAL_BAR;
  size: window.Size;
  constructor(size: window.Size) {
    this.size = size;
  }
}

export class CaptionFloatView {
  private static instance: CaptionFloatView | undefined = undefined;
  private controller?: floatView.FloatViewController;
  private isRunning: boolean = false;
  private storage: LocalStorage = new LocalStorage();

  private constructor() {
    this.storage.setOrCreate('original', '');
    this.storage.setOrCreate('translation', '等待语音输入...');
  }

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

  async start(
    context: common.UIAbilityContext,
    templateType: floatView.FloatViewTemplateType = floatView.FloatViewTemplateType.ROUNDED_RECTANGLE
  ): Promise<boolean> {
    if (this.controller) {
      try {
        await this.stop();
      } catch (stopErr) {
        Log.warn(`[CaptionFloatView] stop before restart: ${JSON.stringify(stopErr)}`);
      }
    }

    try {
      if (typeof floatView.isFloatViewEnabled === 'function') {
        const supported = floatView.isFloatViewEnabled();
        if (!supported) {
          Log.error('[CaptionFloatView] isFloatViewEnabled returned false (device/system unsupported)');
          throw new Error('设备系统未开启或不支持 FloatView');
        }
      }

      // WMS policy: an app cannot run PiP and FloatView concurrently (Error 1031)
      try {
        await PiPManager.getInstance().stopPiP();
      } catch (pipErr) {
        Log.warn(`[CaptionFloatView] stopPiP note: ${JSON.stringify(pipErr)}`);
      }

      const granted = await this.requestPermission(context);
      if (!granted) {
        throw new Error('未获 ohos.permission.FLOAT_VIEW 权限（需检查 ACL Profile）');
      }

      let limits: floatView.FloatViewLimits | undefined = undefined;
      if (typeof floatView.getFloatViewLimits === 'function') {
        limits = floatView.getFloatViewLimits(templateType);
        Log.info(`[CaptionFloatView] Template=${templateType}, limits=${JSON.stringify(limits)}`);
      }

      const config: CaptionFloatConfig = new CaptionFloatConfig(context);
      config.templateType = templateType;
      this.controller = await floatView.create(config);
      Log.info('[CaptionFloatView] controller created');

      this.controller.onStateChange((info: floatView.FloatViewStateChangeInfo) => {
        Log.info(`[CaptionFloatView] state=${JSON.stringify(info)}`);
      });

      this.controller.onRectChange((info: floatView.FloatViewRectChangeInfo) => {
        Log.info(`[CaptionFloatView] rect=${JSON.stringify(info)}`);
      });

      await this.controller.setUIContext('pages/CaptionFloat', this.storage);

      let targetWidth: number = 1152;
      let targetHeight: number = 216;

      if (templateType === floatView.FloatViewTemplateType.ROUNDED_RECTANGLE) {
        if (limits) {
          const maxWidth = limits.maxSize.width;
          const minHeight = limits.minSize.height;
          const maxRatio = (limits.ratioLimits && limits.ratioLimits.length > 0) ? limits.ratioLimits[0].maxRatio : 5.333333333333333;
          // Calculate the flattest/lowest height allowed by maxRatio (e.g. 1152 / 5.333 = 216)
          const heightByRatio = Math.max(minHeight, Math.round(maxWidth / maxRatio));
          targetWidth = maxWidth;
          targetHeight = heightByRatio; // Exactly 1152 x 216 px
        } else {
          targetWidth = 1152;
          targetHeight = 216;
        }
      } else if (limits) {
        targetWidth = limits.maxSize.width;
        targetHeight = limits.maxSize.height;
      }

      const size: FloatWindowSize = new FloatWindowSize(targetWidth, targetHeight);
      const templateProperty: CaptionFloatTemplateProperty = new CaptionFloatTemplateProperty(size);
      templateProperty.templateType = templateType;

      await this.controller.switchTemplate(templateProperty);

      await this.controller.start();
      this.isRunning = true;
      Log.info(`[CaptionFloatView] FloatView (${templateType}) started successfully! size=${targetWidth}x${targetHeight}`);
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
