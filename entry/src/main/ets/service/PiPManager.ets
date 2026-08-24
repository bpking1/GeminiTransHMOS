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

export type PiPActiveChangeListener = (active: boolean) => void;

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

const pipScroller: Scroller = new Scroller();

@Builder
function buildPiPSubtitleView(data: SubtitleData) {
  Column() {
    if (data.displayOutput.length > 0) {
      Scroll(pipScroller) {
        Column() {
          Text(data.displayOutput)
            .width('100%')
            .fontSize(data.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .lineHeight(data.fontSize * 1.38)
            .textAlign(TextAlign.Start)
            .textShadow({ radius: 6, color: '#FF000000', offsetY: 1 })
            .wordBreak(WordBreak.BREAK_ALL)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
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
  .justifyContent(FlexAlign.End)
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

  update(text: string, isLive: boolean, settings?: AppSettings): void {
    const fontSize: number = settings ? settings.captionFontSize : this.data.fontSize;
    const maxLines: number = settings ? settings.subtitleLineCount : this.data.maxLines;
    this.data = new SubtitleData(text.trim(), fontSize, maxLines, isLive);
    if (this.builderNode) {
      this.builderNode.update(this.data);
      setTimeout(() => {
        try {
          pipScroller.scrollEdge(Edge.Bottom);
        } catch (e) {
          // ignore
        }
      }, 10);
    }
  }
}

function calculatePiPContentHeight(lines: number, fontSize: number): number {
  const lineCount: number = Math.max(1, Math.min(4, lines || 2));
  const font: number = Math.max(10, Math.min(36, fontSize || 18));
  const singleLineHeight: number = font * 1.45;
  // Account for 880vp virtual width scaling ratio (~2.5x of physical 350vp screen width)
  const requiredVirtualHeight: number = Math.round((lineCount * singleLineHeight + 20) * 2.45);
  return Math.max(120, Math.min(450, requiredVirtualHeight));
}

export class PiPManager {
  private static instance: PiPManager | undefined = undefined;
  private pipController: PiPWindow.PiPController | undefined = undefined;
  private nodeController: PiPSubtitleNodeController = new PiPSubtitleNodeController();
  private initialized: boolean = false;
  private active: boolean = false;
  private activeChangeListeners: PiPActiveChangeListener[] = [];
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

  isActive(): boolean {
    return this.active;
  }

  addActiveChangeListener(listener: PiPActiveChangeListener): void {
    if (!this.activeChangeListeners.includes(listener)) {
      this.activeChangeListeners.push(listener);
    }
    listener(this.active);
  }

  removeActiveChangeListener(listener: PiPActiveChangeListener): void {
    const index: number = this.activeChangeListeners.indexOf(listener);
    if (index >= 0) {
      this.activeChangeListeners.splice(index, 1);
    }
  }

  private setActive(active: boolean): void {
    if (this.active === active) {
      return;
    }
    this.active = active;
    for (let index = 0; index < this.activeChangeListeners.length; index++) {
      this.activeChangeListeners[index](active);
    }
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
      const fontSize: number = this.currentSettings.captionFontSize || 18;
      const contentHeight: number = calculatePiPContentHeight(lines, fontSize);

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
          this.setActive(true);
        } else if (state === PiPWindow.PiPState.ABOUT_TO_STOP || state === PiPWindow.PiPState.STOPPED) {
          this.setActive(false);
        }
      });

      this.setupTranscriptListener();
      this.initialized = true;
      Log.info('PiPManager: PiPController created successfully with auto-start enabled');
    } catch (error) {
      this.setActive(false);
      const err: BusinessError = error as BusinessError;
      Log.error(`PiPManager: failed to create PiPController: ${err.message ?? JSON.stringify(err)}`);
      throw new Error(`初始化画中画悬浮窗失败：${err.message ?? JSON.stringify(err)}`);
    }
  }

  private listenerSetup: boolean = false;
  private updateScheduled: boolean = false;

  private refreshSubtitle(): void {
    if (this.updateScheduled) {
      return;
    }
    this.updateScheduled = true;
    // Micro-tick batching (16ms = 60fps) ensures zero queue buildup and real-time response
    setTimeout(() => {
      this.updateScheduled = false;
      const text: string = TranslationSession.getInstance().getOutputTranscript();
      this.nodeController.update(text, this.isLiveState, this.currentSettings);
    }, 16);
  }

  private setupTranscriptListener(): void {
    if (this.listenerSetup) {
      return;
    }
    this.listenerSetup = true;
    const listener: SessionListener = {
      onState: (state: SessionState, status: string): void => {
        this.isLiveState = (state === SessionState.LIVE);
        this.refreshSubtitle();
      },
      onTranscript: (input: string, output: string): void => {
        this.refreshSubtitle();
      },
      onError: (message: string): void => {}
    };
    TranslationSession.getInstance().addListener(listener);
  }

  updateSettings(settings: AppSettings): void {
    this.currentSettings = settings;
    const lines: number = this.currentSettings.subtitleLineCount || 2;
    const fontSize: number = this.currentSettings.captionFontSize || 18;
    const newHeight: number = calculatePiPContentHeight(lines, fontSize);
    if (this.pipController) {
      try {
        this.pipController.updateContentSize(880, newHeight);
      } catch (e) {
        Log.warn(`updateContentSize failed: ${JSON.stringify(e)}`);
      }
    }
    this.refreshSubtitle();
  }

  async startPiP(): Promise<void> {
    if (!this.pipController) {
      throw new Error('画中画控制器未就绪');
    }
    try {
      Log.info('PiPManager: starting PiP...');
      await this.pipController.startPiP();
      this.setActive(true);
      Log.info('PiPManager: PiP started successfully');
    } catch (error) {
      this.setActive(false);
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
      this.setActive(false);
    } catch (error) {
      Log.warn(`PiPManager: stopPiP failed: ${JSON.stringify(error)}`);
    }
  }
}
