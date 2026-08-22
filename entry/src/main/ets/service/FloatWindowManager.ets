import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../util/Logger';

export const FLOAT_WINDOW_NAME: string = 'gemini_float_subtitle_window';

export class FloatWindowManager {
  private static instance: FloatWindowManager | undefined = undefined;
  private floatWindow: window.Window | undefined = undefined;
  private showing: boolean = false;

  static getInstance(): FloatWindowManager {
    if (!FloatWindowManager.instance) {
      FloatWindowManager.instance = new FloatWindowManager();
    }
    return FloatWindowManager.instance;
  }

  isShowing(): boolean {
    return this.showing && this.floatWindow !== undefined;
  }

  async show(context: common.UIAbilityContext): Promise<void> {
    if (this.showing && this.floatWindow !== undefined) {
      Log.info('FloatWindowManager: float window is already showing');
      return;
    }

    try {
      Log.info('FloatWindowManager: creating float subtitle window...');
      let defaultDisplay: display.Display;
      try {
        defaultDisplay = display.getDefaultDisplaySync();
      } catch (e) {
        defaultDisplay = { width: 1080, height: 2400 } as display.Display;
      }

      const screenWidth: number = defaultDisplay.width;
      const screenHeight: number = defaultDisplay.height;
      const winWidth: number = Math.min(Math.round(screenWidth * 0.92), 1080);
      const winHeight: number = 520;
      const posX: number = Math.round((screenWidth - winWidth) / 2);
      const posY: number = Math.max(120, screenHeight - winHeight - 320);

      const config: window.Configuration = {
        name: FLOAT_WINDOW_NAME,
        windowType: window.WindowType.TYPE_FLOAT,
        ctx: context
      };

      let win: window.Window;
      try {
        win = await window.createWindow(config);
      } catch (err) {
        Log.warn(`Float window TYPE_FLOAT creation failed (${JSON.stringify(err)}), trying sub-window fallback...`);
        win = await window.createWindow({
          name: FLOAT_WINDOW_NAME,
          windowType: window.WindowType.TYPE_DIALOG,
          ctx: context
        });
      }

      this.floatWindow = win;

      await win.resize(winWidth, winHeight);
      await win.moveWindowTo(posX, posY);
      await win.setWindowBackgroundColor('#00000000');
      await win.setWindowTouchable(true);
      await win.loadContent('pages/FloatingWindowPage');
      await win.showWindow();
      this.showing = true;
      Log.info('FloatWindowManager: float subtitle window displayed successfully');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Log.error(`FloatWindowManager: failed to show float window: ${err.message ?? JSON.stringify(err)}`);
      this.showing = false;
      this.floatWindow = undefined;
      throw new Error(`创建悬浮字幕窗失败：${err.message ?? JSON.stringify(err)}`);
    }
  }

  async hide(): Promise<void> {
    if (!this.floatWindow) {
      this.showing = false;
      return;
    }
    try {
      Log.info('FloatWindowManager: destroying float window...');
      const win = this.floatWindow;
      this.floatWindow = undefined;
      this.showing = false;
      await win.destroyWindow();
      Log.info('FloatWindowManager: float window destroyed');
    } catch (error) {
      Log.warn(`FloatWindowManager: hide failed: ${JSON.stringify(error)}`);
      this.floatWindow = undefined;
      this.showing = false;
    }
  }

  async moveWindow(dx: number, dy: number): Promise<void> {
    if (!this.floatWindow) {
      return;
    }
    try {
      const rect = this.floatWindow.getWindowProperties().windowRect;
      await this.floatWindow.moveWindowTo(rect.left + dx, rect.top + dy);
    } catch (error) {
      Log.debug(`FloatWindowManager: moveWindow error: ${JSON.stringify(error)}`);
    }
  }
}
