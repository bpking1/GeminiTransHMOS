import { common } from '@kit.AbilityKit';
import {
  BuilderNode,
  FrameNode,
  NodeController,
  PiPWindow,
  UIContext
} from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppSettings } from '../model/AppSettings';
import { Log } from '../util/Logger';
import { SettingsStore } from './SettingsStore';
import { SessionListener, SessionState, TranslationSession } from './TranslationSession';

export class SubtitleData {
  output: string = '';
  displayOutput: string = '';
  bgOpacity: number = 75;
  isLive: boolean = false;
}

function getBackgroundColor(opacityPercent: number): string {
  const alphaVal: number = Math.max(0, Math.min(255, Math.round((opacityPercent / 100) * 255)));
  const alphaHex: string = alphaVal.toString(16).padStart(2, '0').toUpperCase();
  return `#${alphaHex}0F0D1A`;
}

function getBorderColor(opacityPercent: number): string {
  if (opacityPercent <= 10) {
    return '#00000000';
  }
  const alphaVal: number = Math.max(0, Math.min(80, Math.round((opacityPercent / 100) * 55)));
  const alphaHex: string = alphaVal.toString(16).padStart(2, '0').toUpperCase();
  return `#${alphaHex}6366F1`;
}

function extractRecentCaption(text: string, maxLen: number = 85): string {
  const trimmed: string = text.trim();
  if (trimmed.length === 0) {
    return '';
  }
  if (trimmed.length <= maxLen) {
    return trimmed;
  }
  const slice: string = trimmed.substring(trimmed.length - maxLen);
  const p1: number = slice.lastIndexOf('。');
  const p2: number = slice.lastIndexOf('！');
  const p3: number = slice.lastIndexOf('？');
  const p4: number = slice.lastIndexOf('\n');
  const p5: number = slice.lastIndexOf('. ');
  const p6: number = slice.lastIndexOf('! ');
  const p7: number = slice.lastIndexOf('? ');
  const maxP: number = Math.max(p1, p2, p3, p4, p5, p6, p7);
  if (maxP >= 0 && maxP < slice.length - 5) {
    return slice.substring(maxP + 1).trim();
  }
  return `…${slice.trim()}`;
}

@Builder
function buildPiPSubtitleView(data: SubtitleData) {
  Column() {
    if (data.displayOutput.length > 0) {
      Text(data.displayOutput)
        .width('100%')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .lineHeight(26)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    } else {
      Text(data.isLive ? '正在实时翻译…' : 'Gemini 翻译已就绪')
        .width('100%')
        .fontSize(15)
        .fontColor('#CBD5E1')
        .textAlign(TextAlign.Center)
    }
  }
  .width('100%')
  .height('100%')
  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  .backgroundColor(getBackgroundColor(data.bgOpacity))
  .borderRadius(18)
  .border({ width: data.bgOpacity > 10 ? 1 : 0, color: getBorderColor(data.bgOpacity) })
  .justifyContent(FlexAlign.Center)
  .alignItems(HorizontalAlign.Center)
}

export class PiPSubtitleNodeController extends NodeController {
  private builderNode: BuilderNode<[SubtitleData]> | null = null;
  private data: SubtitleData = new SubtitleData();

  makeNode(uiContext: UIContext): FrameNode | null {
    this.builderNode = new BuilderNode<[SubtitleData]>(uiContext);
    this.builderNode.build(wrapBuilder<[SubtitleData]>(buildPiPSubtitleView), this.data);
    return this.builderNode.getFrameNode();
  }

  update(output: string, isLive: boolean, settings?: AppSettings): void {
    this.data.output = output;
    this.data.displayOutput = extractRecentCaption(output, 85);
    this.data.isLive = isLive;
    if (settings) {
      this.data.bgOpacity = settings.pipBgOpacity;
    }
    if (this.builderNode) {
      this.builderNode.update(this.data);
    }
  }
}

export class PiPManager {
  private static instance: PiPManager | undefined = undefined;
  private pipController: PiPWindow.PiPController | undefined = undefined;
  private nodeController: PiPSubtitleNodeController = new PiPSubtitleNodeController();
  private initialized: boolean = false;
  private active: boolean = false;
  private isLiveState: boolean = false;
  private currentSettings: AppSettings = new AppSettings();

  static getInstance(): PiPManager {
    if (!PiPManager.instance) {
      PiPManager.instance = new PiPManager();
    }
    return PiPManager.instance;
  }

  getNodeController(): PiPSubtitleNodeController {
    return this.nodeController;
  }

  isSupported(): boolean {
    try {
      return PiPWindow.isPiPEnabled();
    } catch (e) {
      Log.warn(`isPiPEnabled check failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  async init(context: common.UIAbilityContext, xComponentController: XComponentController): Promise<void> {
    if (this.initialized && this.pipController) {
      return;
    }

    try {
      Log.info('PiPManager: Initializing Pure Subtitle PiPWindow...');
      try {
        this.currentSettings = await SettingsStore.load(context);
      } catch (e) {
        Log.warn(`PiPManager loadSettings: ${JSON.stringify(e)}`);
      }

      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: xComponentController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: 840,
        contentHeight: 280,
        customUIController: this.nodeController
      };

      this.pipController = await PiPWindow.create(config);
      this.pipController.setAutoStartEnabled(true);

      this.pipController.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        Log.info(`PiP stateChange: state=${state}, reason=${reason}`);
        if (state === PiPWindow.PiPState.ABOUT_TO_START || state === PiPWindow.PiPState.STARTED) {
          this.active = true;
        } else if (state === PiPWindow.PiPState.ABOUT_TO_STOP || state === PiPWindow.PiPState.STOPPED) {
          this.active = false;
        }
      });

      this.setupTranscriptListener();
      this.initialized = true;
      Log.info('PiPManager: PiPController created successfully with auto-start enabled');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Log.error(`PiPManager: failed to create PiPController: ${err.message ?? JSON.stringify(err)}`);
      throw new Error(`初始化画中画悬浮窗失败：${err.message ?? JSON.stringify(err)}`);
    }
  }

  private setupTranscriptListener(): void {
    const listener: SessionListener = {
      onState: (state: SessionState, status: string): void => {
        this.isLiveState = (state === SessionState.LIVE);
        this.nodeController.update(
          TranslationSession.getInstance().getOutputTranscript(),
          this.isLiveState,
          this.currentSettings
        );
      },
      onTranscript: (input: string, output: string): void => {
        this.nodeController.update(output, this.isLiveState, this.currentSettings);
      },
      onError: (message: string): void => {}
    };
    TranslationSession.getInstance().addListener(listener);
  }

  updateSettings(settings: AppSettings): void {
    this.currentSettings = settings;
    this.nodeController.update(
      TranslationSession.getInstance().getOutputTranscript(),
      this.isLiveState,
      this.currentSettings
    );
  }

  async startPiP(): Promise<void> {
    if (!this.pipController) {
      throw new Error('画中画控制器未就绪');
    }
    try {
      Log.info('PiPManager: starting PiP...');
      await this.pipController.startPiP();
      this.active = true;
      Log.info('PiPManager: PiP started successfully');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Log.error(`PiPManager: startPiP failed: ${err.message ?? JSON.stringify(err)}`);
      throw new Error(`启动画中画悬浮窗失败：${err.message ?? JSON.stringify(err)}`);
    }
  }

  async stopPiP(): Promise<void> {
    if (!this.pipController || !this.active) {
      return;
    }
    try {
      Log.info('PiPManager: stopping PiP...');
      await this.pipController.stopPiP();
      this.active = false;
    } catch (error) {
      Log.warn(`PiPManager: stopPiP failed: ${JSON.stringify(error)}`);
    }
  }
}
