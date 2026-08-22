import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { TranslationSession } from '../service/TranslationSession';

const DOMAIN: number = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'GeminiLiveTranslate', 'Ability created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(DOMAIN, 'GeminiLiveTranslate',
          'Failed to load page: %{public}s', JSON.stringify(error));
      }
    });
  }

  onBackground(): void {
    // A phone user must always have a visible privacy indicator and control
    // while audio is captured, so translation stops when the app backgrounds.
    TranslationSession.getInstance().stop();
  }

  onDestroy(): void {
    TranslationSession.getInstance().stop();
  }
}

