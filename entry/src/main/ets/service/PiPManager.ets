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
  displayOutput: string = '';
  fontSize: number = 18;
  maxLines: number = 2;
  isLive: boolean = false;

  constructor(displayOutput: string = '', fontSize: number = 18, maxLines: number = 2, isLive: boolean = false) {
    this.displayOutput = displayOutput;
    this.fontSize = fontSize;
    this.maxLines = maxLines;
    this.isLive = isLive;
  }
}

@Builder
function buildPiPSubtitleView(data: SubtitleData) {
  Column() {
    if (data.displayOutput.length > 0) {
      Text(data.displayOutput)
        .width('100%')
        .fontSize(data.fontSize)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .lineHeight(data.fontSize * 1.38)
        .textAlign(TextAlign.Start)
        .textShadow({ radius: 6, color: '#FF000000', offsetY: 1 })
        .maxLines(data.maxLines)
        .textOverflow({ overflow: TextOverflow.None })
        .wordBreak(WordBreak.BREAK_ALL)
    } else {
      Text(data.isLive ? '正在聆听并实时翻译…' : 'Gemini 实时字幕已就绪')
        .width('100%')
        .fontSize(Math.max(11, data.fontSize - 2))
        .fontColor('#94A3B8')
        .textAlign(TextAlign.Start)
        .textShadow({ radius: 4, color: '#CC000000', offsetY: 1 })
    }
  }
  .width('100%')
  .height('100%')
  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  .backgroundColor('#000000')
  .justifyContent(FlexAlign.Center)
  .alignItems(HorizontalAlign.Start)
}

export class PiPSubtitleNodeController extends NodeController {
  private builderNode: BuilderNode<[SubtitleData]> | null = null;
  private data: SubtitleData = new SubtitleData();

  makeNode(uiContext: UIContext): FrameNode | null {
    this.builderNode = new BuilderNode<[SubtitleData]>(uiContext);
    this.builderNode.build(wrapBuilder<[SubtitleData]>(buildPiPSubtitleView), this.data);
    return this.builderNode.getFrameNode();
  }

  update(recentSubtitle: string, isLive: boolean, settings?: AppSettings): void {
    const fontSize: number = settings ? settings.captionFontSize : this.data.fontSize;
    const maxLines: number = settings ? settings.subtitleLineCount : this.data.maxLines;
    this.data = new SubtitleData(recentSubtitle.trim(), fontSize, maxLines, isLive);
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
      Log.info('PiPManager: Initializing Multi-line Subtitle PiPWindow...');
      try {
        this.currentSettings = await SettingsStore.load(context);
      } catch (e) {
        Log.warn(`PiPManager loadSettings: ${JSON.stringify(e)}`);
      }

      const lines: number = this.currentSettings.subtitleLineCount || 2;
      const contentHeight: number = Math.max(160, Math.min(360, lines * 65 + 60));

      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: xComponentController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: 880,
        contentHeight: contentHeight,
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
        const lines: number = this.currentSettings.subtitleLineCount || 2;
        this.nodeController.update(
          TranslationSession.getInstance().getRecentOutputSubtitle(lines),
          this.isLiveState,
          this.currentSettings
        );
      },
      onTranscript: (input: string, output: string): void => {
        const lines: number = this.currentSettings.subtitleLineCount || 2;
        this.nodeController.update(
          TranslationSession.getInstance().getRecentOutputSubtitle(lines),
          this.isLiveState,
          this.currentSettings
        );
      },
      onError: (message: string): void => {}
    };
    TranslationSession.getInstance().addListener(listener);
  }

  updateSettings(settings: AppSettings): void {
    this.currentSettings = settings;
    const lines: number = this.currentSettings.subtitleLineCount || 2;
    this.nodeController.update(
      TranslationSession.getInstance().getRecentOutputSubtitle(lines),
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
