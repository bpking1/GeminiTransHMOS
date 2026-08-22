import { common } from '@kit.AbilityKit';
import {
  BuilderNode,
  FrameNode,
  NodeController,
  PiPWindow,
  UIContext
} from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppSettings, languageName } from '../model/AppSettings';
import { Log } from '../util/Logger';
import { SettingsStore } from './SettingsStore';
import { SessionListener, SessionState, TranslationSession } from './TranslationSession';

export class SubtitleData {
  output: string = '';
  input: string = '';
  displayOutput: string = '';
  displayInput: string = '';
  targetLanguage: string = 'zh';
  audioSource: string = 'system';
  showOriginal: boolean = true;
  status: string = '已就绪';
  isLive: boolean = false;
}

function extractRecentCaption(text: string, maxLen: number = 75): string {
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
    // 1. Android Live Caption Style Header Bar
    Row() {
      // Live indicator + Title
      Row() {
        Circle({ width: 7, height: 7 })
          .fill(data.isLive ? '#10B981' : '#F59E0B')
          .margin({ right: 6 })
        Text(data.audioSource === 'system' ? '系统内录' : '麦克风')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#7C3AED')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#2E1B4E')
          .borderRadius(5)
          .margin({ right: 6 })
        Text('实时翻译')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E2E8F0')
      }

      Blank()

      // Target language badge
      Text(`→ ${languageName(data.targetLanguage)}`)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor('#A78BFA')
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        .backgroundColor('#231D36')
        .borderRadius(10)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 6 })

    // 2. High-contrast Real-time Subtitle Body
    Column() {
      if (data.displayOutput.length > 0) {
        Text(data.displayOutput)
          .width('100%')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .lineHeight(23)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Row() {
          Text(data.isLive ? '正在聆听并实时翻译…' : 'Gemini 翻译悬浮窗就绪')
            .fontSize(14)
            .fontColor('#94A3B8')
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }

      // 3. Optional Original Speech Text
      if (data.showOriginal && data.displayInput.length > 0) {
        Text(data.displayInput)
          .width('100%')
          .fontSize(12)
          .fontColor('#93C5FD')
          .lineHeight(16)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
  .width('100%')
  .height('100%')
  .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  .backgroundColor('#E60F0D1A')
  .borderRadius(18)
  .border({ width: 1, color: '#334B3B6E' })
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

  update(input: string, output: string, isLive: boolean, settings?: AppSettings): void {
    this.data.input = input;
    this.data.output = output;
    this.data.displayOutput = extractRecentCaption(output, 75);
    this.data.displayInput = extractRecentCaption(input, 60);
    this.data.isLive = isLive;
    if (settings) {
      this.data.targetLanguage = settings.targetLanguage;
      this.data.audioSource = settings.audioSource;
      this.data.showOriginal = settings.showOriginal;
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
      Log.info('PiPManager: Initializing Android-style Live Caption PiPWindow...');
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
        contentHeight: 300,
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
          TranslationSession.getInstance().getInputTranscript(),
          TranslationSession.getInstance().getOutputTranscript(),
          this.isLiveState,
          this.currentSettings
        );
      },
      onTranscript: (input: string, output: string): void => {
        this.nodeController.update(input, output, this.isLiveState, this.currentSettings);
      },
      onError: (message: string): void => {}
    };
    TranslationSession.getInstance().addListener(listener);
  }

  updateSettings(settings: AppSettings): void {
    this.currentSettings = settings;
    this.nodeController.update(
      TranslationSession.getInstance().getInputTranscript(),
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
