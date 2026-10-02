import { router } from '@kit.ArkUI';

/**
 * 启动页：显示应用启动图，短暂停留后进入主页面。
 * 做法参考 HarmonyOS6-WebView-Shell（MIT）：独立 Splash 页 + EntryAbility 先加载它。
 */
@Entry
@Component
struct Splash {
  private timerId: number = 0;

  aboutToAppear(): void {
    // 1.2 秒后进入主页面（够看到启动图，又不拖沓）
    this.timerId = setTimeout(() => {
      router.replaceUrl({ url: 'pages/Index' });
    }, 1200);
  }

  aboutToDisappear(): void {
    clearTimeout(this.timerId);
  }

  build() {
    Stack() {
      Image($r('app.media.splash'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
