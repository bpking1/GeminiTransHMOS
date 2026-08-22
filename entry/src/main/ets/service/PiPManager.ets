import { common } from '@kit.AbilityKit';
import {
  BuilderNode,
  FrameNode,
  NodeController,
  PiPWindow,
  UIContext
} from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../util/Logger';
import { SessionListener, SessionState, TranslationSession } from './TranslationSession';

export class SubtitleData {
  output: string = '';
  input: string = '';
}

@Builder
function buildPiPSubtitleView(data: SubtitleData) {
  Column() {
    Row() {
      Circle({ width: 6, height: 6 })
        .fill('#34D399')
        .margin({ right: 4 })
      Text('实时翻译')
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor('#9CA3AF')
    }
    .width('100%')
    .margin({ bottom: 4 })

    Text(data.output.length > 0 ? data.output : '等待翻译中…')
      .width('100%')
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .lineHeight(22)
      .maxLines(3)
      .textOverflow({ overflow: TextOverflow.Ellipsis })

    if (data.input.length > 0) {
      Text(data.input)
        .width('100%')
        .fontSize(12)
        .fontColor('#C7D2FE')
        .lineHeight(16)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 3 })
    }
  }
  .width('100%')
  .height('100%')
  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  .backgroundColor('#E6110E1C')
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

  update(input: string, output: string): void {
    this.data.input = input;
    this.data.output = output;
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
      Log.info('PiPManager: Initializing PiPWindow controller...');
      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: xComponentController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: 800,
        contentHeight: 360,
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
      onState: (state: SessionState, status: string): void => {},
      onTranscript: (input: string, output: string): void => {
        this.nodeController.update(input, output);
      },
      onError: (message: string): void => {}
    };
    TranslationSession.getInstance().addListener(listener);
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
