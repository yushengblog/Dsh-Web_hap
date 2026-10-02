import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'dsh', '%{public}s', 'onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'dsh', '%{public}s', 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 窗口设置：全屏布局 + 隐藏底部导航条指示器（消除底部那条白边）
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(DOMAIN, 'dsh', '%{public}s', 'full screen layout enabled');
      }).catch(() => {
      });
      // 参考 HarmonyOS6-WebView-Shell：关掉底部导航条指示器
      try {
        win.setSpecificSystemBarEnabled('navigationIndicator', false);
      } catch (e) {
      }
      // 浅色背景下系统栏图标用深色
      win.setWindowSystemBarProperties({
        statusBarContentColor: '#000000'
      }).catch(() => {
      });
    } catch (err) {
      hilog.error(DOMAIN, 'dsh', 'window setup failed: %{public}s', JSON.stringify(err));
    }

    // 直接加载主页面（不再经过 Splash：历史版本卡在这里导致白屏）
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'dsh', 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'dsh', 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
