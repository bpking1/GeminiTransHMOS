import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'GeminiLive';

export class Log {
  static info(msg: string): void {
    console.info(`[${TAG}] ${msg}`);
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    console.warn(`[${TAG}] ${msg}`);
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    console.error(`[${TAG}] ${msg}`);
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }

  static debug(msg: string): void {
    console.debug(`[${TAG}] ${msg}`);
    hilog.debug(DOMAIN, TAG, '%{public}s', msg);
  }
}
