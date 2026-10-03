import { webview } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common, bundleManager, wantConstant, Want } from '@kit.AbilityKit';
import { window, promptAction } from '@kit.ArkUI';
import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { inputMethod } from '@kit.IMEKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rcp } from '@kit.RemoteCommunicationKit';

const DOMAIN: number = 0x0000;

// 阶段：0 = 选站点，1 = 连接中，2 = 显示网页
const PHASE_PICKER: number = 0;
const PHASE_LOADING: number = 1;
const PHASE_WEB: number = 2;

// 网页增强总开关。
// true  = 正常运行（注入自动登录、站点快速切换行、状态上报等）
// false = 诊断模式：完全不注入。用于确认"手机端 DSH 的某些功能失灵"是不是本 App 的注入引起的。
//         （实测：手机自带浏览器功能正常、本 App 不正常 → 先靠这个开关一刀切开）
const INJECT_ENABLED: boolean = true;

const EMPTY_URL: string = 'about:blank';
const BUILD_TAG: string = '构建 v10-01-3712'

// ── WebDAV 站点备份 ────────────────────────────────────────────────
// 备份目录固定为 <WebDAV 根>/DSH/Dsh_zhandian（首次备份时自动 MKCOL 创建）。
// 主文件 dsh-sites.json 固定名（方便手动下载），同时留一份带时间戳的历史副本。
// ── 回车键 = 换行 ────────────────────────────────────────────────
// 背景：DSH 的网页输入框把回车一律当"发送"，而且**没有**"回车发送/换行"的设置项
//   （ui-conversation 的 busyEnter 只管"忙碌时排队还是插话"，不是这个）。
// 鸿蒙侧我们已用 onInterceptKeyboardAttach 把系统软键盘的回车键声明为「换行」，
//   用户实测：**按键标签确实变成了"换行"**，但点下去仍然发送 ——
//   因为输入法发出来的仍是一个普通回车，DSH 的处理器照旧发送。
// 所以最后一步必须由我们拦住：在 **文档开始**（抢在 DSH 脚本之前）用 window 捕获阶段
//   注册 keydown，拦下不带修饰键的回车并 stopImmediatePropagation，
//   **不 preventDefault** —— 让 contenteditable 的默认行为插入换行。
// 发送改用界面上的发送按钮（蓝色圆形）。
// 注：带 Shift/Ctrl/Alt/Meta 的回车不拦（原本就不发送，走原生换行即可）。
// ── 上下文里的图片：点击就拦下来，官方那个**根本不打开** ──────────────
// 用户要求：会话里的图片点开就用本 App 的查看器，不要官方那个（原来两个都开、
//   或者官方先开我再关，会有闪烁也不可靠）。
// ⚠️ 拦截**必须在文档开始注册**才抢得过 DSH 的点击处理器 ——
//   而渲染函数在晚注入的查看器里，所以这里只"拦 + 记 + 发事件"，
//   由查看器接事件渲染（同时把路径留在 __dshImgWant 上做兜底）。
// 只拦会话区的内联图；右侧栏里的预览走另一条路（那是由页签渲染的，见 activeImagePath）。
const CONTEXT_IMG_JS: string = '(function(){try{'
  + 'document.addEventListener("click",function(e){try{'
  + 'var t=e.target;if(!t||t.tagName!=="IMG")return;'
  + 'if(t.closest&&t.closest("[data-dockkit-content]"))return;'
  + 'var s=t.getAttribute("src")||"";'
  + 'var m=s.match(/[?&]path=([^&]+)/);if(!m)return;'
  + 'var p;try{p=decodeURIComponent(m[1]);}catch(x){return;}'
  + 'if(!/[.](png|jpe?g|jpe|gif|webp|bmp|ico|avif|tiff?|heic|heif)$/i.test(p))return;'
  + 'e.preventDefault();e.stopImmediatePropagation();'
  + 'window.__dshImgWant=p;'
  + 'try{window.dispatchEvent(new CustomEvent("dsh-img-want",{detail:p}));}catch(x){}'
  + '}catch(x){}},true);}catch(e){}})()';

const ENTER_AS_NEWLINE_JS: string = '(function(){try{'
  + 'window.addEventListener("keydown",function(e){try{'
  + 'if(e.key!=="Enter"&&e.keyCode!==13)return;'
  + 'var t=e.target;if(!(t&&t.closest))return;'
  + 'if(!t.closest("[contenteditable=\\"true\\"],[contenteditable=\\"\\"],textarea"))return;'
  + 'if(e.shiftKey||e.ctrlKey||e.metaKey||e.altKey)return;'
  + 'e.stopImmediatePropagation();'
  + '}catch(x){}},true);}catch(e){}})()';

const DAV_DIR: string = '/DSH/Dsh_zhandian';
const DAV_FILE: string = '/dsh-sites.json';
const KEY_DAV_URL: string = 'dav_url';
const KEY_DAV_USER: string = 'dav_user';
const KEY_DAV_PASS: string = 'dav_pass';
const KEY_DAV_AUTO: string = 'dav_auto';
const KEY_DAV_LAST: string = 'dav_last';
// 上次记录的深色模式（用于冷启动第一帧就上对颜色，避免闪白）
const KEY_DARK: string = 'dark_mode';

// 备份文件结构
interface BackupFile {
  app?: string;
  type?: string;
  version?: number;
  exportedAt?: string;
  groups?: Group[];
}

// 一条地址
interface Address {
  name: string;   // 备注（可空）
  url: string;
  user: string;   // 可选账号（自动登录用）
  pass: string;   // 可选密码
  off: boolean;   // 停用
  link: string;   // '' 未测 | 'ok' 能打开 | 'fail' 打不开
  err: string;    // 上次失败原因
}

interface Group {
  name: string;
  items: Address[];
  // 版本号：地址顺序变化时 +1。用于让外层 ForEach 的 key 变化 ——
  // 否则地址换序后外层 key 不变，ArkUI 不会重建内层列表，界面看起来"点了没反应"。
  ver?: number;
}

interface ShellBridge {
  getGroups: () => string;
  getCurrent: () => string;
  saveGroups: (json: string) => void;
  switchTo: (g: number, i: number) => void;
  getSafeTop: () => number;
  getSafeBottom: () => number;
  log: (m: string) => void;
  openSites: () => void;
  // 下载并用系统应用打开（office/pdf）
  openFile: (json: string) => void;
  setOverlay: (v: number) => void;
  // 自建文件查看器的开合状态（返回键/侧滑据此先关它）
  setFileFix: (v: number) => void;
  setDialog: (v: number) => void;
  getCurLabel: () => string;
  openSwitcher: () => void;
  // 诊断：把一段文字直接打到界面红条上
  dbg: (m: string) => void;
  // 网页上报当前是否深色（原生页面与状态栏条据此上色）
  setDark: (v: number) => void;
}

function mkAddr(name: string, url: string): Address {
  return { name: name, url: url, user: '', pass: '', off: false, link: '', err: '' };
}

// 出厂默认不预置任何站点：首次使用请自行添加，或用「WebDAV 站点备份 / 恢复」导入。
const DEFAULT_GROUPS: Group[] = [];

const STORE_NAME: string = 'dsh_shell';
const KEY_GROUPS: string = 'groups4';
const KEY_CUR: string = 'cur';
const KEY_VISITED: string = 'visited';

@Entry
@Component
struct Index {
  @State groups: Group[] = DEFAULT_GROUPS;
  @State curG: number = 0;
  @State curI: number = 0;
  @State phase: number = -1;  // -1=未定（等 loadStore 决定），避免首帧闪一下站点页
  @State panelMode: string = 'list';
  @State working: Group[] = [];
  @State hint: string = '正在连接…';
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  @State probing: boolean = false;
  @State probeHint: string = '';

  private lastBackTime: number = 0;
  private injectJs: string = '';
  private probeQueue: string[] = [];
  private probePos: number = 0;
  private probeG: number = 0;
  private probeI: number = 0;
  private probeTimer: number = -1;
  private sslIgnored: boolean = false;
  private loadFailed: boolean = false;
  private probeHadError: boolean = false;
  private probeSslIgnored: boolean = false;
  private probeController: webview.WebviewController = new webview.WebviewController();
  private controller: webview.WebviewController = new webview.WebviewController();
  private store: preferences.Preferences | null = null;
  private visited: boolean = false;
  private webOverlay: boolean = false;
  // 状态栏双色：直接镜像网页里量到的真实颜色，这样深色/浅色主题都能自动跟随
  // （不再硬编码 #F9FAFC / #FFFFFF / #DBDCDE）
  // App 自身原生页面是否用深色（由网页上报的配色亮度推导，随 DSH 主题自动切换）
  @State isDark: boolean = false;
  private sysBarDark: boolean = false;
  private sysBarApplied: boolean = false;
  // 网页里是否有"大浮层弹窗"（如 DSH 设置窗）打开；打开时不显示左侧栏的「当前连接情况」行，
  // 否则那个原生浮层会盖在设置窗上面（用户实测反馈）。
  @State dialogOpen: boolean = false;
  // 站点快速切换面板（点左侧栏那行"当前连接情况"弹出）
  @State showSwitcher: boolean = false;
  // 当前窗口宽度(vp)：折叠屏断点适配（Compact<600 / Medium 600-840 / Expanded>840）
  @State winW: number = 0;
  @State dbgText: string = '';
  // 站点页"排序模式"：开启后每个系统/地址右侧出现"上移/下移"按钮（独占一行，避免被挤压点不到）
  @State sortMode: boolean = false;
  // 进入排序模式前的快照：点「返回」放弃本次排序改动，点「完成」才保留
  @State sortBackup: Group[] = [];
  // 「当前连接」文字缓存：@Builder 里调用普通方法不会随状态变化重新计算，所以存成 @State
  @State curLabelText: string = '';
  @State injectLen: number = 0;
  @State lastErr: string = '';
  @State injectCount: number = 0;
  // ── 诊断用（排查"手机端文件查看器打不开"）──
  // webConsoleErr：网页控制台里的报错，直接显示在界面上，便于真机取证（不用连电脑）
  @State webConsoleErr: string = '';
  // 自建文件查看器是否开着
  @State fileFixOpen: boolean = false;
  // 从安装包读出的版本号（形如 v1.0.12 (1000012)）——用于让用户核对装的是哪一版
  @State verText: string = BUILD_TAG;
  // 网页增强总开关：置 false 可完全停掉所有注入，用来判断"是不是我的注入引起的"
  private injectEnabled: boolean = INJECT_ENABLED;

  // ── WebDAV 备份配置与状态 ──
  @State davUrl: string = '';
  @State davUser: string = '';
  @State davPass: string = '';
  @State davAuto: boolean = false;
  @State davBusy: boolean = false;
  @State davMsg: string = '';
  @State davLast: string = '';
  // 连接自检
  @State davTesting: boolean = false;
  @State davTestLog: string = '';
  @State davTestOk: boolean = false;
  // 传输进度
  @State davProgress: number = 0;        // 0-100
  @State davProgressText: string = '';   // 例如「上传 12.3 / 45.6 KB」
  @State davPhase: string = '';          // 正在做什么（建目录 / 上传 / 下载）
  private davTimer: number = -1;
  private davReady: boolean = false;   // 配置读完之前不触发自动备份

  aboutToAppear(): void {
    this.readVersion();
    this.loadStore();
    this.measureSafeArea();
    this.loadInjectJs();
    // 启动即落盘：把当前站点（含账号密码）写入本地存储，之后升级/覆盖安装都保留
    this.saveStore();
    setTimeout(() => {
      if (this.visited) {
        // 之前进过站点：直接回到那个站点。
        // 若它挂了就一直停在转圈页，底部「站点」随时可切换，不会卡死。
        this.connect(this.curG, this.curI);
      }
      // 未进过站点时**不再自动探测**（用户定稿）：
      //   不点的地址没必要探；真正要保的只是"点了之后白屏能退回来"，
      //   那由 connect() 之后的 watchWhiteScreen() 负责。
      //   想看全部红绿灯时，用户在站点页手动点「重新检测」。
    }, 300);


  }

  addLog(m: string): void {
    hilog.info(DOMAIN, 'DshShell', '%{public}s', m);
    console.info('DshLog ' + m);
  }

  // 取 URL 的主机名（用于判断页面到底加载了哪一条）
  hostOf(url: string): string {
    let u = url;
    const i = u.indexOf('://');
    if (i > 0) {
      u = u.substring(i + 3);
    }
    const slash = u.indexOf('/');
    if (slash >= 0) {
      u = u.substring(0, slash);
    }
    const colon = u.lastIndexOf(':');
    if (colon > 0) {
      u = u.substring(0, colon);
    }
    return u;
  }

  // 清掉 Web 历史：否则"后退"会退回加载前的 about:blank 白屏页
  clearWebHistory(): void {
    setTimeout(() => {
      try {
        this.controller.clearHistory();
      } catch (e) {
      }
    }, 600);
  }

  currentUrl(): string {
    try {
      const g = this.groups[this.curG];
      if (g && g.items && g.items.length > 0 && g.items[this.curI] && g.items[this.curI].url) {
        return g.items[this.curI].url;
      }
    } catch (e) {
    }
    return EMPTY_URL;
  }

  loadInjectJs(): void {
    // 读取 rawfile 里的注入脚本。三条路兜底：TextDecoder / 手工字节解码 / 异步 API。
    // 任何一条成功即可（早先只有 TextDecoder 一条路，异常被吞掉后 injectJs 为空，
    // 导致所有注入功能静默失效 —— 弹窗点不掉、logo 拦不住，全都源于此）。
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = ctx.resourceManager.getRawFileContentSync('inject.js');
      try {
        const decoder = util.TextDecoder.create('utf-8');
        this.injectJs = decoder.decodeToString(bytes);
      } catch (e2) {
        let s = '';
        for (let i = 0; i < bytes.length; i++) {
          s += String.fromCharCode(bytes[i]);
        }
        this.injectJs = s;
      }
    } catch (e) {
      this.injectJs = '';
    }
    this.injectLen = this.injectJs.length;
  }

  // 从安装包自身读版本号，保证"界面显示的版本" == "实际安装的版本"。
  // （以前显示的是构建时间戳，用户没法核对装的是哪一版 —— 用户反馈后改掉）
  readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info && info.versionName) {
        this.verText = 'v' + info.versionName + ' (' + info.versionCode.toString() + ')';
      }
    } catch (e) {
      this.verText = BUILD_TAG;
    }
  }

  // 主题取色：浅色 / 深色两套。所有原生页面颜色都走这里，
  // isDark 随网页配色自动切换（见 applySysBarIcons），所以 DSH 换主题时 App 一起变。
  tc(light: string, dark: string): string {
    return this.isDark ? dark : light;
  }

  // 系统状态栏图标颜色跟随明暗（深色 → 图标用白色），否则深色模式下看不见时间/电量。
  // 明暗由网页上报（setDark），不再自己算颜色。
  applySysBarIcons(dark: boolean): void {
    try {
      if (this.sysBarApplied && dark === this.sysBarDark) {
        return;
      }
      this.sysBarDark = dark;
      this.sysBarApplied = true;
      const ctx = this.getUIContext().getHostContext();
      window.getLastWindow(ctx).then((w: window.Window) => {
        try {
          w.setWindowSystemBarProperties({
            statusBarContentColor: dark ? '#FFFFFF' : '#000000',
            navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
          });
        } catch (e) {
        }
      }).catch(() => {
      });
    } catch (e) {
    }
  }

  measureSafeArea(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      window.getLastWindow(ctx).then((w: window.Window) => {
        try {
          const t = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
          const b = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
          this.safeTop = Math.round(px2vp(t));
          this.safeBottom = Math.round(px2vp(b));
        } catch (e) {
        }
      }).catch(() => {
      });
    } catch (e) {
    }
  }

  // ── 记录结果 ───────────────────────────────────────────────────
  markLink(gi: number, ai: number, value: string): void {
    try {
      const w = JSON.parse(JSON.stringify(this.groups)) as Group[];
      if (w[gi] && w[gi].items && w[gi].items[ai]) {
        w[gi].items[ai].link = value;
        if (value === 'ok') {
          w[gi].items[ai].err = '';
        }
        // 组内数据变了：bump 版本号，否则外层 ForEach 的 key 不变 → 界面不刷新
        const lv = w[gi].ver;
        w[gi].ver = (lv ? lv : 0) + 1;
        this.groups = [];
        this.groups = w;
        this.saveStore();
      }
    } catch (e) {
    }
  }

  setErr(gi: number, ai: number, msg: string): void {
    try {
      const w = JSON.parse(JSON.stringify(this.groups)) as Group[];
      if (w[gi] && w[gi].items && w[gi].items[ai]) {
        w[gi].items[ai].err = msg;
        this.groups = w;
        this.saveStore();
      }
    } catch (e) {
    }
  }

  // ── 后台检测：隐藏 Web 依次真加载每条地址 ───────────────────────
  // 只在用户**手动点「重新检测」**时启动（不再开机自动跑）。
  startProbeAll(): void {
    const q: string[] = [];
    for (let gi = 0; gi < this.groups.length; gi++) {
      const items = this.groups[gi].items ? this.groups[gi].items : [];
      for (let ai = 0; ai < items.length; ai++) {
        if (!items[ai].off && items[ai].url.length > 4) {
          q.push(gi.toString() + '-' + ai.toString());
        }
      }
    }
    this.probeQueue = q;
    this.probePos = 0;
    this.probing = q.length > 0;
    this.nextProbe();
  }

  // 取消全部探测：清队列 + 停超时 + 让隐藏 Web 卸载当前页面（停止加载/省流量/省内存）
  // 用户要求：一旦退出站点页面就自动取消全部探测。
  cancelProbe(): void {
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
    this.probeQueue = [];
    this.probePos = 0;
    this.probing = false;
    this.probeHint = '';
    try {
      this.probeController.loadUrl(EMPTY_URL);
    } catch (e) {
    }
  }

  nextProbe(): void {
    if (this.probePos >= this.probeQueue.length) {
      this.probing = false;
      this.probeHint = '';
      return;
    }
    const parts = this.probeQueue[this.probePos].split('-');
    const gi = parseInt(parts[0], 10);
    const ai = parseInt(parts[1], 10);
    const items = this.groups[gi].items;
    if (!items || !items[ai]) {
      this.probePos++;
      this.nextProbe();
      return;
    }
    const idx = this.probePos;
    this.probeG = gi;
    this.probeI = ai;
    this.probeHint = '正在检测 ' + (idx + 1).toString() + '/' + this.probeQueue.length.toString() + ' …';
    this.probeSslIgnored = false;
    this.probeHadError = false;
    try {
      this.probeController.loadUrl(items[ai].url);
    } catch (e) {
    }
    this.probeTimer = setTimeout(() => {
      this.probeTimer = -1;
      this.finishProbe(false);
    }, 6000);
  }

  onProbeEnd(): void {
    if (!this.probing) {
      return;
    }
    // 只有页面真的停在本次探测的主机上，才算这条打开成功
    const g = this.groups[this.probeG];
    const a = (g && g.items && g.items[this.probeI]) ? g.items[this.probeI] : null;
    if (!a) {
      this.finishProbe(false);
      return;
    }
    if (this.probeHadError) {
      return;
    }
    const want = this.hostOf(a.url);
    setTimeout(() => {
      try {
        this.probeController.runJavaScript('location.host')
          .then((h: string) => {
            const got = h ? h.replace(/"/g, '') : '';
            if (got.length > 0 && got.indexOf(want) >= 0) {
              this.finishProbe(true);
            }
          })
          .catch(() => {
          });
      } catch (e) {
      }
    }, 600);
  }

  // 用「页面里有没有内容」判断是否真的打开成功
  confirmLoaded(isProbe: boolean): void {
    const ctl: webview.WebviewController = isProbe ? this.probeController : this.controller;
    setTimeout(() => {
      try {
        ctl.runJavaScript('String((document.body&&document.body.innerText)?document.body.innerText.length:0)')
          .then((len: string) => {
            const n = parseInt(len, 10);
            if (isNaN(n) || n <= 0) {
              return;
            }
            if (isProbe) {
              this.finishProbe(true);
            } else if (this.phase === PHASE_LOADING) {
              this.markLink(this.curG, this.curI, 'ok');
              this.phase = PHASE_WEB;
              this.watchWhiteScreen();
              this.visited = true;
              this.saveStore();
              this.injectAll();
            }
          })
          .catch(() => {
          });
      } catch (e) {
      }
    }, 300);
  }

  finishProbe(ok: boolean): void {
    if (!this.probing) {
      return;
    }
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
    this.markLink(this.probeG, this.probeI, ok ? 'ok' : 'fail');
    if (!ok) {
      this.setErr(this.probeG, this.probeI, '打不开');
    }
    this.probePos++;
    setTimeout(() => {
      this.nextProbe();
    }, 900);
  }

  // ── 连接某条地址 ────────────────────────────────────────────────
  connect(g: number, i: number): void {
    if (g < 0 || g >= this.groups.length) {
      return;
    }
    const items = this.groups[g].items;
    if (!items || i < 0 || i >= items.length || items[i].off) {
      return;
    }
    // 离开站点页去连站点：取消还在跑的探测
    this.cancelProbe();
    this.curG = g;
    this.curI = i;
    this.saveStore();
    this.refreshCurLabel();
    this.sslIgnored = false;
    this.loadFailed = false;
    this.lastErr = '';
    this.phase = PHASE_LOADING;
    this.hint = '正在连接…';
    try {
      // 先停掉可能正在进行的加载：否则"正在加载"状态下 loadUrl 会被忽略，
      // 表现就是"从站点页点击一直转圈、最后 E-2"，而重启后首次加载却正常。
      this.controller.stop();
    } catch (e) {
    }
    setTimeout(() => {
      try {
        this.controller.loadUrl(items[i].url);
      } catch (e) {
      }
    }, 60);
    setTimeout(() => {
      if (this.phase === PHASE_LOADING) {
        // 超时兜底：**也进网页**。实测这类站点页面早已能显示，只是没触发 onProgressChange/onPageEnd，
        // 继续卡在"连不上"反而挡住了本来正常的页面。真打不开时网页自己会显示错误，
        // 用户还能用侧滑返回或站点页切换。
        this.markLink(g, i, 'ok');
        this.phase = PHASE_WEB;
              this.watchWhiteScreen();
        this.visited = true;
        this.saveStore();
      }
    }, 12000);
  }

  curLabel(): string {
    const g = this.groups[this.curG];
    if (!g) {
      return '（未选择）';
    }
    const a = (g.items && g.items[this.curI]) ? g.items[this.curI] : null;
    if (!a) {
      return g.name;
    }
    const nm = (a.name && a.name.length > 0) ? a.name : a.url;
    return g.name + ' / ' + nm + '   ' + a.url;
  }

  // 进入/切换会话时 DSH 会把焦点丢进输入框并自动唤起输入法；这里主动失焦 + 收起输入法。
  // 只 stopInputSession 不够：那只是收起键盘，输入框仍聚焦、手指一碰又弹。
  dismissKeyboard(): void {
    try {
      this.controller.runJavaScript('(function(){try{var a=document.activeElement;if(a&&a.blur){a.blur();}var b=document.body;if(b&&b.focus){b.focus();}}catch(e){}})()');
    } catch (e) {
    }
    try {
      inputMethod.getController().stopInputSession();
    } catch (e) {
    }
  }

  // 从站点页回到网页（站点页的「返回」按钮 + 系统侧滑/返回键都会走这里）
  backToWeb(): void {
    // 离开站点页：取消还在跑的探测
    this.cancelProbe();
    if (this.visited) {
      this.phase = PHASE_WEB;
              this.watchWhiteScreen();
      this.panelMode = 'list';
    } else {
      this.connect(this.curG, this.curI);
    }
  }

  refreshCurLabel(): void {
    const s = this.curLabel();
    if (s !== this.curLabelText) {
      this.curLabelText = s;
    }
    this.pushCurLabel();
  }

  // 把「当前连接情况」文字**主动推送**到网页左侧栏那一行。
  // 用户定稿：不切站点就不该反复轮询原生 —— 所以改成"变了才推"。
  pushCurLabel(): void {
    if (this.phase !== PHASE_WEB) {
      return;
    }
    try {
      const js = '(function(){try{var e=document.getElementById("dsh-curlbl");'
        + 'if(e&&e.textContent!==' + JSON.stringify(this.curLabelText) + '){'
        + 'e.textContent=' + JSON.stringify(this.curLabelText) + ';}}catch(x){}})()';
      this.js(js);
    } catch (e) {
    }
  }

  backToPicker(): void {
    this.phase = PHASE_PICKER;
    this.panelMode = 'list';
    this.hint = '正在连接…';
  }

  // 进入网页后再确认一次"是不是白屏"：真打不开时页面内容极少，
  // 这时自动退回站点页并提示，避免把用户困在一片白里（重进 App 也会自动重连到同一片白）。
  watchWhiteScreen(): void {
    setTimeout(() => {
      if (this.phase !== PHASE_WEB) {
        return;
      }
      try {
        this.controller.runJavaScript('(document.body?document.body.innerText.length:0)').then((r: string) => {
          const n = parseInt(r, 10);
          if (!isNaN(n) && n < 20) {
            this.markLink(this.curG, this.curI, 'fail');
            this.setErr(this.curG, this.curI, '空白页');
            promptAction.showToast({ message: '这条打不开（空白页），已回到站点页', duration: 2500 });
            this.backToPicker();
          }
        }).catch(() => {
        });
      } catch (e) {
      }
    }, 2500);
  }

  // ── 编辑 ───────────────────────────────────────────────────────
  openEdit(): void {
    this.working = JSON.parse(JSON.stringify(this.groups)) as Group[];
    this.panelMode = 'edit';
  }

  // ── 排序：系统和系统内的地址都能上下移动 ──
  // 直接改 working 数组顺序，保存后写回 groups，因此站点页与主页下拉菜单的顺序会同步变化。
  @State dragIdx: number = -1;

  // 拖拽排序：把 from 位置的系统移动到 to 位置
  moveGroupTo(from: number, to: number): void {
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    if (from < 0 || from >= w.length || to < 0 || to >= w.length || from === to) {
      return;
    }
    const item = w.splice(from, 1)[0];
    w.splice(to, 0, item);
    // 先清空再赋值：强制 @State 刷新（直接赋值同引用可能不触发）
    this.working = [];
    this.working = w;
    this.dbgText = 'drag ' + from.toString() + ' -> ' + to.toString();
  }

  @Builder
  dragCardView(idx: number) {
    Row({ space: 8 }) {
      Text('拖动')
        .fontSize(12)
        .fontColor('#BBD0FF')
      Text((this.working[idx] && this.working[idx].name && this.working[idx].name.length > 0)
        ? this.working[idx].name : ('系统 ' + (idx + 1).toString()))
        .fontSize(15)
        .fontColor('#FFFFFF')
    }
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(12)
    .backgroundColor('#0A59F7')
    .shadow({ radius: 16, color: this.tc('#33000000', '#66000000'), offsetX: 0, offsetY: 6 })
  }

  moveGroup(gi: number, d: number): void {
    this.dbgText = 'moveG ' + gi.toString() + ',' + d.toString();
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    const t = gi + d;
    if (t < 0 || t >= w.length) {
      return;
    }
    const tmp = w[gi];
    w[gi] = w[t];
    w[t] = tmp;
    this.working = [];
    this.working = w;
  }

  moveAddr(gi: number, ai: number, d: number): void {
    this.dbgText = 'moveA ' + gi.toString() + ',' + ai.toString() + ',' + d.toString();
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    if (gi < 0 || gi >= w.length) {
      return;
    }
    const items = w[gi].items;
    const t = ai + d;
    if (t < 0 || t >= items.length) {
      return;
    }
    const tmp = items[ai];
    items[ai] = items[t];
    items[t] = tmp;
    this.working = [];
    this.working = w;
  }

  addSystem(): void {
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    w.push({ name: '新系统', items: [mkAddr('', 'http://')] });
    this.working = w;
  }

  removeSystem(gi: number): void {
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    w.splice(gi, 1);
    this.working = w;
  }

  addAddress(gi: number): void {
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    if (!w[gi].items) {
      w[gi].items = [];
    }
    w[gi].items.push(mkAddr('', 'http://'));
    this.working = w;
  }

  removeAddress(gi: number, ai: number): void {
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    w[gi].items.splice(ai, 1);
    this.working = w;
  }

  toggleOff(gi: number, ai: number): void {
    const w = JSON.parse(JSON.stringify(this.working)) as Group[];
    w[gi].items[ai].off = !w[gi].items[ai].off;
    // 组内数据变了：bump 版本号，让外层 ForEach 的 key 变化 → 重建节点 → 按钮文字立即更新
    const tv = w[gi].ver;
    w[gi].ver = (tv ? tv : 0) + 1;
    this.working = [];
    this.working = w;
  }

  saveWorking(): void {
    const clean: Group[] = [];
    for (let gi = 0; gi < this.working.length; gi++) {
      const g = this.working[gi];
      const items: Address[] = [];
      const src = g.items ? g.items : [];
      for (let ai = 0; ai < src.length; ai++) {
        const a = src[ai];
        if (a.url && a.url.length > 4) {
          items.push({ name: a.name, url: a.url, user: a.user, pass: a.pass, off: a.off, link: '', err: '' });
        }
      }
      if (items.length > 0) {
        clean.push({ name: g.name, items: items });
      }
    }
    if (clean.length > 0) {
      this.groups = clean;
      this.curG = 0;
      this.curI = 0;
      this.saveStore();
      this.startProbeAll();
    }
    this.panelMode = 'list';
  }

  loadStore(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = preferences.getPreferencesSync(ctx, { name: STORE_NAME });
      const raw = this.store.getSync(KEY_GROUPS, '') as string;
      if (raw.length > 2) {
        const arr = JSON.parse(raw) as Group[];
        if (arr.length > 0) {
          for (let gi = 0; gi < arr.length; gi++) {
            const items = arr[gi].items ? arr[gi].items : [];
            for (let ai = 0; ai < items.length; ai++) {
              const a = items[ai];
              if (!a.name) { a.name = ''; }
              if (!a.url) { a.url = ''; }
              if (!a.user) { a.user = ''; }
              if (!a.pass) { a.pass = ''; }
              if (!a.off) { a.off = false; }
              if (!a.link) { a.link = ''; }
              if (!a.err) { a.err = ''; }
            }
          }
          this.groups = arr;
        }
      }
      const v = this.store.getSync(KEY_VISITED, '') as string;
      this.visited = (v === '1');
      // WebDAV 备份配置
      this.davUrl = this.store.getSync(KEY_DAV_URL, '') as string;
      this.davUser = this.store.getSync(KEY_DAV_USER, '') as string;
      this.davPass = this.store.getSync(KEY_DAV_PASS, '') as string;
      this.davLast = this.store.getSync(KEY_DAV_LAST, '') as string;
      const da = this.store.getSync(KEY_DAV_AUTO, '0') as string;
      this.davAuto = (da !== '0');
      this.davReady = true;
      // 冷启动先按上次记录的明暗上色，网页上报后会再校正
      const dk = this.store.getSync(KEY_DARK, '0') as string;
      this.isDark = (dk === '1');
      // 进过站点：首帧就进"连接中"，直接回到上次那个站点，不再闪站点页
      this.phase = this.visited ? PHASE_LOADING : PHASE_PICKER;
      this.refreshCurLabel();
      const cur = this.store.getSync(KEY_CUR, '') as string;
      if (cur.indexOf(',') > 0) {
        const parts = cur.split(',');
        const g = parseInt(parts[0], 10);
        const i = parseInt(parts[1], 10);
        if (g >= 0 && g < this.groups.length) {
          const items = this.groups[g].items;
          if (items && i >= 0 && i < items.length) {
            this.curG = g;
            this.curI = i;
          }
        }
      }
    } catch (e) {
    }
  }


  // ══ WebDAV 站点备份 ═════════════════════════════════════════════
  // 用途：把站点配置（系统 + 地址 + 账号密码）备份到自己的 WebDAV，
  //       换机/清空后可以一键恢复，也可以直接在浏览器里下载 dsh-sites.json。
  davBase(): string {
    let u: string = this.davUrl ? this.davUrl : '';
    while (u.length > 0 && u.charAt(u.length - 1) === '/') {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  davAuthHeader(): string {
    if (!this.davUser || this.davUser.length === 0) {
      return '';
    }
    try {
      const enc = new util.Base64Helper();
      const raw = new util.TextEncoder().encodeInto(this.davUser + ':' + this.davPass);
      return 'Basic ' + enc.encodeToStringSync(raw);
    } catch (e) {
      return '';
    }
  }

  // 发一个 WebDAV 请求。MKCOL 不在 RequestMethod 枚举里，只能断言透传
  //（GET/PUT/POST/DELETE/HEAD/OPTIONS 走枚举，别的走断言）。
  private davSend(method: string, path: string, body: string,
                  onDone: (code: number, text: string) => void,
                  report?: boolean): void {
    const url: string = this.davBase() + path;
    const req = http.createHttp();
    const header: Record<string, string> = {};
    header['Content-Type'] = 'application/json; charset=utf-8';
    const auth: string = this.davAuthHeader();
    if (auth.length > 0) {
      header['Authorization'] = auth;
    }
    // 传输进度上报（只有备份/恢复这类大请求才需要）
    if (report === true) {
      req.on('dataSendProgress', (info: http.DataSendProgressInfo) => {
        try {
          const total: number = info.totalSize;
          if (total > 0) {
            this.davProgress = Math.floor(info.sendSize * 100 / total);
            this.davProgressText = '已发送 ' + this.davKb(info.sendSize) + ' / ' + this.davKb(total);
          }
        } catch (e) {
        }
      });
      req.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
        try {
          const total: number = info.totalSize;
          if (total > 0) {
            this.davProgress = Math.floor(info.receiveSize * 100 / total);
            this.davProgressText = '已接收 ' + this.davKb(info.receiveSize) + ' / ' + this.davKb(total);
          }
        } catch (e) {
        }
      });
    }
    let m: http.RequestMethod = http.RequestMethod.GET;
    if (method === 'PUT') {
      m = http.RequestMethod.PUT;
    } else if (method === 'POST') {
      m = http.RequestMethod.POST;
    } else if (method === 'DELETE') {
      m = http.RequestMethod.DELETE;
    } else if (method === 'HEAD') {
      m = http.RequestMethod.HEAD;
    } else if (method === 'OPTIONS') {
      m = http.RequestMethod.OPTIONS;
    } else if (method !== 'GET') {
      m = method as http.RequestMethod;
    }
    req.request(url, {
      method: m,
      header: header,
      extraData: body,
      connectTimeout: 12000,
      readTimeout: 30000
    }).then((resp: http.HttpResponse) => {
      let txt: string = '';
      if (typeof resp.result === 'string') {
        txt = resp.result as string;
      }
      onDone(resp.responseCode, txt);
      req.destroy();
    }).catch((e: BusinessError) => {
      const msg: string = e && e.message ? e.message : 'network error';
      onDone(-1, msg);
      req.destroy();
    });
  }

  // MKCOL 不在 http.RequestMethod 的封闭枚举里（枚举只有 OPTIONS/GET/HEAD/POST/PUT/DELETE/TRACE/CONNECT），
  // 用 http 发 MKCOL 会被原生层拒绝，返回 "HTTP -1 Parameter error"（实测踩到）。
  // 改用 rcp（Remote Communication Kit）：它的 HttpMethod 类型显式允许任意方法名
  //   export type HttpMethod = 'GET' | ... | (string & NonNullable<unknown>);
  // 只把 MKCOL 交给 rcp，PUT/GET/DELETE 仍走 http —— 因为 http 的传输进度事件更好用。
  private davMkcol(path: string, onDone: (code: number, msg: string) => void): void {
    const url: string = this.davBase() + path;
    try {
      const headers: rcp.RequestHeaders = {};
      const auth: string = this.davAuthHeader();
      if (auth.length > 0) {
        headers['Authorization'] = auth;
      }
      const session = rcp.createSession();
      const req = new rcp.Request(url, 'MKCOL', headers);
      session.fetch(req).then((resp: rcp.Response) => {
        onDone(resp.statusCode, '');
        try {
          session.close();
        } catch (e) {
        }
      }).catch((e: BusinessError) => {
        const m: string = e && e.message ? e.message : 'rcp error';
        onDone(-1, m);
        try {
          session.close();
        } catch (e2) {
        }
      });
    } catch (e) {
      onDone(-1, 'rcp 不可用');
    }
  }

  // 依次创建 /DSH 和 /DSH/Dsh_zhandian。已存在时服务器返回 405（或 301/302），都算成功。
  // 注意：MKCOL 失败**不再直接判定失败** —— 目录可能早就存在，交给后续 PUT 定论，
  //       这样即使某些服务端禁用了 MKCOL，只要目录存在就仍能备份。
  private davEnsureDir(onDone: (ok: boolean, note: string) => void): void {
    this.davMkcol('/DSH', (c1: number, _t1: string) => {
      this.davMkcol(DAV_DIR, (c2: number, _t2: string) => {
        const ok1: boolean = (c1 >= 200 && c1 < 300) || c1 === 405 || c1 === 301 || c1 === 302;
        const ok2: boolean = (c2 >= 200 && c2 < 300) || c2 === 405 || c2 === 301 || c2 === 302;
        if (ok1 && ok2) {
          onDone(true, '目录已存在或创建成功');
        } else {
          onDone(true, 'MKCOL: /DSH=' + c1.toString() + '，' + DAV_DIR + '=' + c2.toString()
            + '（已跳过建目录，直接尝试写入）');
        }
      });
    });
  }

  davKb(n: number): string {
    if (n < 1024) {
      return n.toString() + ' B';
    }
    const kb: number = n / 1024;
    if (kb < 1024) {
      return (Math.round(kb * 10) / 10).toString() + ' KB';
    }
    return (Math.round(kb / 1024 * 100) / 100).toString() + ' MB';
  }

  // 连接自检：一步步验证"地址能不能通 / 认证对不对 / 能不能建目录 / 能不能写文件"
  // 每步都往 davTestLog 追加一行，失败时能直接看出卡在哪。
  davTest(): void {
    if (this.davBase().length < 8) {
      this.davTestLog = '请先填写 WebDAV 地址（要包含 http:// 或 https://）';
      this.davTestOk = false;
      return;
    }
    if (this.davTesting) {
      return;
    }
    this.davTesting = true;
    this.davTestOk = false;
    this.davTestLog = '';
    this.davPhase = '';
    this.davProgress = 0;
    this.davProgressText = '';
    const base: string = this.davBase();
    const probe: string = DAV_DIR + '/.dsh-probe.json';

    this.davTestLog = '① 地址：' + base + '\n';

    // ① OPTIONS 根目录：验证可达 + 认证 + 是否启用 WebDAV
    this.davSend('OPTIONS', '/', '', (c1: number, _t1: string) => {
      if (c1 === -1) {
        this.davTestLog = this.davTestLog + '   ❌ 连不上（网络不通 / 地址写错 / 端口不对）\n';
        this.davTesting = false;
        return;
      }
      if (c1 === 401 || c1 === 403) {
        this.davTestLog = this.davTestLog + '   ❌ HTTP ' + c1.toString()
          + '：认证未通过（检查用户名/密码；若服务端只允许 NTLM/Digest，本 App 不支持）\n';
        this.davTesting = false;
        return;
      }
      if (c1 < 200 || c1 >= 400) {
        this.davTestLog = this.davTestLog + '   ❌ HTTP ' + c1.toString() + '（服务端拒绝）\n';
        this.davTesting = false;
        return;
      }
      this.davTestLog = this.davTestLog + '   ✅ HTTP ' + c1.toString() + '：可达且认证通过\n';

      // ② 建目录
      this.davTestLog = this.davTestLog + '② 创建目录 ' + DAV_DIR + '\n';
      this.davEnsureDir((ok: boolean, em: string) => {
        if (!ok) {
          this.davTestLog = this.davTestLog + '   ❌ ' + em + '\n';
          this.davTesting = false;
          return;
        }
        if (em.indexOf('MKCOL:') === 0) {
          this.davTestLog = this.davTestLog + '   ⚠ ' + em + '\n';
        } else {
          this.davTestLog = this.davTestLog + '   ✅ ' + em + '\n';
        }

        // ③ 写入探测文件
        this.davTestLog = this.davTestLog + '③ 写入测试文件（验证可写）\n';
        const body: string = '{"probe":"dsh","at":"' + new Date().toISOString() + '"}';
        this.davSend('PUT', probe, body, (c3: number, _t3: string) => {
          if (c3 < 200 || c3 >= 300) {
            this.davTestLog = this.davTestLog + '   ❌ HTTP ' + c3.toString()
              + '：不能写入（检查 IIS 的 WebDAV 创作规则是否允许写入、目录 NTFS 权限）\n';
            this.davTesting = false;
            return;
          }
          this.davTestLog = this.davTestLog + '   ✅ 写入成功\n';

          // ④ 读回
          this.davTestLog = this.davTestLog + '④ 读回测试文件\n';
          this.davSend('GET', probe, '', (c4: number, t4: string) => {
            if (c4 < 200 || c4 >= 300) {
              this.davTestLog = this.davTestLog + '   ❌ HTTP ' + c4.toString() + '：不能读取\n';
            } else if (t4.indexOf('dsh') < 0) {
              this.davTestLog = this.davTestLog + '   ⚠ 读取成功但内容不符（可能有缓存/代理）\n';
            } else {
              this.davTestLog = this.davTestLog + '   ✅ 读取成功，内容一致\n';
            }
            // ⑤ 清理
            this.davSend('DELETE', probe, '', (c5: number, _t5: string) => {
              if (c5 >= 200 && c5 < 300) {
                this.davTestLog = this.davTestLog + '⑤ 清理测试文件：✅ 已删除\n';
              } else {
                this.davTestLog = this.davTestLog + '⑤ 清理测试文件：⚠ HTTP ' + c5.toString()
                  + '（可手动删除 ' + probe + '）\n';
              }
              this.davTestOk = true;
              this.davTestLog = this.davTestLog + '\n✅ 全部通过，可以正常备份 / 恢复';
              this.davTesting = false;
              promptAction.showToast({ message: 'WebDAV 连接正常', duration: 2000 });
            });
          });
        });
      });
    });
  }

  davStamp(): string {
    const d = new Date();
    const p2 = (n: number): string => (n < 10 ? ('0' + n.toString()) : n.toString());
    return d.getFullYear().toString() + p2(d.getMonth() + 1) + p2(d.getDate())
      + '-' + p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds());
  }

  // 备份内容：自带说明字段，便于人工查看；groups 就是站点数据本体
  buildBackupJson(): string {
    return '{"app":"Dsh-Web_hap","type":"dsh-sites","version":1,"exportedAt":"'
      + new Date().toISOString() + '","count":' + this.groups.length.toString()
      + ',"current":{"g":' + this.curG.toString() + ',"i":' + this.curI.toString()
      + '},"groups":' + JSON.stringify(this.groups) + '}';
  }

  saveDavCfg(): void {
    try {
      if (this.store === null) {
        return;
      }
      this.store.putSync(KEY_DAV_URL, this.davUrl);
      this.store.putSync(KEY_DAV_USER, this.davUser);
      this.store.putSync(KEY_DAV_PASS, this.davPass);
      this.store.putSync(KEY_DAV_AUTO, this.davAuto ? '1' : '0');
      this.store.putSync(KEY_DAV_LAST, this.davLast);
      this.store.flush();
    } catch (e) {
    }
  }

  // 站点有改动时延迟自动备份（防抖，避免探测过程里频繁上传）
  scheduleAutoBackup(): void {
    if (!this.davReady || !this.davAuto || this.davBase().length < 8) {
      return;
    }
    if (this.davTimer >= 0) {
      clearTimeout(this.davTimer);
    }
    this.davTimer = setTimeout(() => {
      this.davTimer = -1;
      this.davBackup(false);
    }, 8000);
  }

  davBackup(manual: boolean): void {
    if (this.davBase().length < 8) {
      this.davMsg = '请先填写 WebDAV 地址';
      return;
    }
    if (this.davBusy) {
      return;
    }
    this.davBusy = true;
    this.davMsg = '正在备份…';
    this.davProgress = 0;
    this.davProgressText = '';
    this.davPhase = '建目录';
    const payload: string = this.buildBackupJson();
    const stamp: string = this.davStamp();
    this.davEnsureDir((ok: boolean, note: string) => {
      if (!ok) {
        this.davBusy = false;
        this.davPhase = '';
        this.davMsg = note;
        return;
      }
      const mkNote: string = note;
      this.davPhase = '上传主文件';
      this.davSend('PUT', DAV_DIR + DAV_FILE, payload, (c1: number, _t1: string) => {
        if (c1 < 200 || c1 >= 300) {
          this.davBusy = false;
          this.davPhase = '';
          this.davMsg = '上传失败：HTTP ' + c1.toString()
            + '（检查 WebDAV 是否允许 PUT、目录是否存在且可写、账号密码是否正确）'
            + (mkNote.indexOf('MKCOL:') === 0 ? ('｜' + mkNote) : '');
          return;
        }
        this.davPhase = '上传历史副本';
        this.davProgress = 0;
        this.davProgressText = '';
        this.davSend('PUT', DAV_DIR + '/dsh-sites-' + stamp + '.json', payload, (c2: number, _t2: string) => {
          this.davBusy = false;
          this.davPhase = '';
          this.davProgress = 100;
          this.davLast = stamp;
          this.saveDavCfg();
          if (c2 >= 200 && c2 < 300) {
            this.davMsg = '备份成功 · ' + stamp + '（' + this.davKb(payload.length) + '）';
          } else {
            this.davMsg = '主文件已备份，历史副本失败：HTTP ' + c2.toString();
          }
          if (manual) {
            promptAction.showToast({ message: this.davMsg, duration: 2500 });
          }
        }, true);
      }, true);
    });
  }

  davRestore(): void {
    if (this.davBase().length < 8) {
      this.davMsg = '请先填写 WebDAV 地址';
      return;
    }
    if (this.davBusy) {
      return;
    }
    this.davBusy = true;
    this.davMsg = '正在读取备份…';
    this.davProgress = 0;
    this.davProgressText = '';
    this.davPhase = '下载备份文件';
    this.davSend('GET', DAV_DIR + DAV_FILE, '', (code: number, text: string) => {
      this.davBusy = false;
      this.davPhase = '';
      if (code === 404) {
        this.davMsg = '服务器上没有找到备份文件（先做一次备份）';
        return;
      }
      if (code < 200 || code >= 300) {
        this.davMsg = '读取失败：HTTP ' + code.toString();
        return;
      }
      try {
        const b = JSON.parse(text) as BackupFile;
        const gs: Group[] = b && b.groups ? (b.groups as Group[]) : [];
        if (gs.length === 0) {
          this.davMsg = '备份文件里没有站点数据';
          return;
        }
        // 逐条补默认值，避免旧备份缺字段导致崩溃
        const fixed: Group[] = [];
        for (let gi = 0; gi < gs.length; gi++) {
          const src = gs[gi];
          const items: Address[] = [];
          const rawItems = src.items ? src.items : [];
          for (let ai = 0; ai < rawItems.length; ai++) {
            const a = rawItems[ai];
            items.push({
              name: a.name ? a.name : '',
              url: a.url ? a.url : '',
              user: a.user ? a.user : '',
              pass: a.pass ? a.pass : '',
              off: a.off ? true : false,
              link: a.link ? a.link : '',
              err: a.err ? a.err : ''
            });
          }
          fixed.push({ name: src.name ? src.name : '未命名', items: items });
        }
        this.groups = [];
        this.groups = fixed;
        this.curG = 0;
        this.curI = 0;
        this.saveStore();
        this.refreshCurLabel();
        let n = 0;
        for (let gi = 0; gi < fixed.length; gi++) {
          n = n + fixed[gi].items.length;
        }
        this.davMsg = '恢复成功：' + fixed.length.toString() + ' 个系统 / ' + n.toString() + ' 条地址';
        promptAction.showToast({ message: this.davMsg, duration: 3000 });
      } catch (e) {
        this.davMsg = '备份内容不是合法 JSON';
      }
    }, true);
  }

  saveStore(): void {
    try {
      if (this.store === null) {
        return;
      }
      this.store.putSync(KEY_GROUPS, JSON.stringify(this.groups));
      this.store.putSync(KEY_CUR, this.curG.toString() + ',' + this.curI.toString());
      this.store.putSync(KEY_VISITED, this.visited ? '1' : '0');
      this.store.flush();
      // 站点有改动 → 延迟自动备份到 WebDAV（若已开启）
      this.scheduleAutoBackup();
    } catch (e) {
    }
  }

  // 网页增强：全部用"直接写在 ArkTS 里的短脚本"注入。
  // ⚠️ 不能从 rawfile 读脚本文件（那条路在本项目完全不执行，见 README 坑 27/30）。
  // ⚠️ 也不能"连续同步调用" runJavaScript：实测只有最前面少数几个生效、后面的被丢掉。
  //    这里改成队列 + 250ms 间隔逐个发。
  private jsQueue: string[] = [];
  private jsBusy: boolean = false;

  js(code: string): void {
    this.jsQueue.push(code);
    this.pumpJs();
  }

  pumpJs(): void {
    if (this.jsBusy || this.jsQueue.length === 0) {
      return;
    }
    this.jsBusy = true;
    const code = this.jsQueue.shift() as string;
    try {
      this.controller.runJavaScript(code);
    } catch (e) {
    }
    setTimeout(() => {
      this.jsBusy = false;
      this.pumpJs();
    }, 250);
  }

  // ── 自建文件查看器（纯文本 + Markdown 渲染）──────────────────────
  // 背景：手机端 DSH 的文件查看器对 dsh-resource://file/… 一律显示
  //   "文件资源服务不可用"（DSH 客户端的 file 资源提供方在本 App 的 ArkWeb 里没注册）。
  // 方案：不依赖那个提供方，改用**同源 fetch** 直调 /api/workspaceFiles/read 取内容自行渲染。
  //
  // ★触发方式：**由"错误状态本身"触发**，不认入口
  //   （文件树 / 聊天提及 / 变更审查「打开文件」都会走 file 地址、都会报错，
  //     但只有文件树那行有 [data-files-entry] 属性 —— 旧实现只监听它，别的入口就"点了没反应"）。
  //
  // ★路径确定：**收集全部候选，逐个试 read，取第一个成功的**
  //   （报错态下文件页签的 [data-path-label] 可能是空的，只取"最后一个"会取到空）。
  //   候选：① 所有 [data-path-label] 里像路径的值 ② [data-textpreview-url] 里 URL 编码的路径
  //         ③ 文件树点击记录 ④ 页签标题里的文件名。全失败时弹诊断浮层列出看到的东西。
  //
  // 会话标识来源：读 DOM（[data-sidebar-right-session] / [data-conversation-session]）。
  //   ★钩 window.fetch/XHR 嗅探实测**捕获数为 0** —— 客户端在模块加载时就缓存了原始引用。
  //
  // 接口契约（实测）：
  //   POST /api/workspaceFiles/read
  //   {"type":"client-request","rpcId":"…","method":"workspaceFiles/read",
  //    "payload":{"args":{"workspaceFileScopeId":"session-…","path":"相对或绝对路径",
  //                       "range":{"offset":1,"limit":2000}}}}
  //   → {"result":{"ok":true,"value":{absolutePath,bytes,offset,lines,eof,text}}}
  //   ⚠️ offset 是**行号且最小为 1**（传 0 返回 bad-request）。
  //
  // ★Markdown 查看（本次新增）：
  //   .md / .markdown 默认按 **Markdown 渲染**，其余文件默认纯文本；
  //   工具条上可随时切换（按钮文字就是当前状态，一眼看得出 —— 只靠颜色深浅用户看不出，踩过）。
  //   渲染器是**自己写的轻量实现**，不依赖任何 CDN / 外部库
  //   （本 App 面向内网自建系统，可能上不了外网）。
  //   支持：标题 / 粗体 / 斜体 / 删除线 / 行内代码 / 代码块 / 有序无序列表 /
  //         引用块 / 分隔线 / 表格 / 链接 / 图片。
  //   · 相对路径的图片不渲染（会 404），只显示替代文字与路径
  //   · 链接**不跳转**（点击被拦下）—— 否则 WebView 会离开 DSH 页面，用户就"回不来"了
  //
  // 其他历次反馈对应的改动：
  //   · 打开后自动关掉原版那个报错页签（★用"从错误元素往上爬 data-dockkit-content → 点
  //     data-dockkit-tab-close"精确命中，与标题无关；别用 [aria-selected=true]，它会匹配到
  //     会话行等无关元素而认错目标）
  //   · 等得太久 → 文件树点击时立刻预取（轮询 100ms）
  //   · 侧滑关闭 → 左边缘起滑 + 系统返回键（经 setFileFix 上报开合状态）
  //   · 关闭查看器时也再收一次报错页签，并延迟 350ms 重试
  // ── 下载并用**系统应用**打开 office / pdf ──────────────────────────
  // 为什么必须走系统应用：真机实测 DSH 自带的 docx/xlsx/pptx/pdf 渲染器
  //   在 ArkWeb 里起不来（报「预览器 xxx 不可用」，注意**不是**"文件资源服务不可用"），
  //   所以"交还官方"对这几类是死路。
  // 下载用 http + WebView 的 Cookie（同源，带凭据），避免把文件搬成 base64 过大。
  // 清理"交给系统应用打开"用的缓存目录，避免越攒越大。
  // 策略：**保留最近 1 小时内动过的**（那个可能正被外部应用阅读，删了会让对方打不开），
  //       其余一律删除。每次打开新文件前调用 —— 这样目录里长期只有最近几个文件。
  // 备注：放在 cacheDir（应用私有缓存），系统在存储紧张时也会回收。
  cleanOpenWithDir(dir: string): void {
    try {
      const names = fileIo.listFileSync(dir);
      const now = Date.now();
      for (let i = 0; i < names.length; i++) {
        try {
          const full = dir + '/' + names[i];
          const st = fileIo.statSync(full);
          // HarmonyOS 的 stat.mtime 单位是**秒**
          if (now - st.mtime * 1000 > 3600000) {
            fileIo.unlinkSync(full);
          }
        } catch (e) {
        }
      }
    } catch (e) {
    }
  }
  async openWithSystem(json: string): Promise<void> {
    let url = '';
    let name = 'file';
    let mime = 'application/octet-stream';
    try {
      const o = JSON.parse(json) as Record<string, string>;
      url = o.url;
      name = o.name || name;
      mime = o.mime || mime;
    } catch (e) {
      return;
    }
    if (!url) {
      return;
    }
    try {
      let cookie = '';
      try {
        cookie = await webview.WebCookieManager.getCookie(url);
      } catch (e) {
      }
      const req = http.createHttp();
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Cookie': cookie },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 120000
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        promptAction.showToast({ message: '下载失败（HTTP ' + resp.responseCode + '）' });
        return;
      }
      const buf = resp.result as ArrayBuffer;
      const ctx = getContext(this) as common.UIAbilityContext;
      const dir = ctx.cacheDir + '/openwith';
      try {
        fileIo.mkdirSync(dir);
      } catch (e) {
      }
      // 先清理旧文件再写新的（见 cleanOpenWithDir 注释）
      this.cleanOpenWithDir(dir);
      const safe = name.replace(/[\\\\/:*?"<>|]/g, '_');
      const fp = dir + '/' + safe;
      const file = fileIo.openSync(fp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      const uri = fileUri.getUriFromPath(fp);
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: mime,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      await ctx.startAbility(want);
    } catch (e) {
      const err = e as BusinessError;
      // 没有可打开的应用时系统会报错，这里给一句人话提示
      promptAction.showToast({ message: '无法用系统应用打开：' + (err && err.message ? err.message : '未知原因') });
    }
  }
  injectFileFix(): void {
    this.js('(function(){if(window.__dshFf){return;}window.__dshFf=1;'
      + 'var timer=null,lastPath=null,lastUsed=null,prefetch=null,shown=false,errSig="",imgDone="",docDone="";'
      + 'function getScope(){try{'
      + 'var el=document.querySelector("[data-sidebar-right-session]")||document.querySelector("[data-conversation-session]");'
      + 'if(el)return el.getAttribute("data-sidebar-right-session")||el.getAttribute("data-conversation-session");'
      + '}catch(e){}return null;}'
      + 'function base(p){var k=Math.max(p.lastIndexOf("/"),p.lastIndexOf("\\\\"));return k>=0?p.substring(k+1):p;}'
      // 二进制/图片后缀：这些**不归本查看器管**，要留给官方查看器。
      // 【踩过的坑】原来只要看到"不可用"就接管、完全不看类型，
      //   结果图片被本查看器拦下（它只会渲染文本）→ 用户看不了图（反馈）。
      + 'function isBin(p){return /[.](png|jpe?g|jpe|gif|webp|bmp|ico|tiff?|heic|heif|avif|svgz|mp4|mov|avi|mkv|webm|flv|wmv|mp3|wav|flac|aac|ogg|opus|m4a|zip|rar|7z|gz|tgz|bz2|xz|tar|apk|hap|app|exe|msi|dll|so|dylib|bin|dat|db|sqlite3?|pdf|docx?|xlsx?|pptx?|odt|ods|odp|ttf|otf|woff2?|eot|class|jar|wasm|pyc|iso|img|dmg|pkg|deb|rpm)$/i.test(String(p||""));}'
+ 'function isImg(p){return /[.](png|jpe?g|jpe|gif|webp|bmp|ico|avif|tiff?|heic|heif)$/i.test(String(p||""));}'
      // "其他二进制"（图片之外的二进制）：这些仍然**完全不接管**，交给官方查看器。
      + 'function isOtherBin(p){return isBin(p)&&!isImg(p);}'
      // 相对路径 → 绝对路径（/api/file 接口要求绝对路径）
      + 'function absOf(p){if(!p)return null;p=String(p).replace(/\\//g,"\\\\");'
      + 'if(/^[a-zA-Z]:\\\\/.test(p))return p;'
      + 'if(p.charAt(0)==="\\\\")return p;'
      + 'var root=null;'
      + 'try{var r=document.querySelector("[data-files-root]");if(r)root=r.getAttribute("data-files-root");}catch(e){}'
      + 'if(!root){try{var l=document.querySelectorAll("[data-path-label]");'
      + 'for(var i=0;i<l.length;i++){var tt=(l[i].innerText||"").trim();'
      + 'if(/^[a-zA-Z]:\\\\/.test(tt)){var s=tt.substring(0,tt.lastIndexOf("\\\\"));if(s)root=s;}}}catch(e){}}'
      + 'if(!root)return null;'
      + 'return String(root).replace(/[\\\\/]+$/,"")+"\\\\"+p;}'
      // ── 图片查看器（带缩放 —— 官方那个不能放大，这里补上）──
      // 字节直接用 DSH 自己的接口：<img src="/api/file?path=<绝对路径 urlencode>">
      // （实测：200 / Content-Type: image/jpeg / 字节数与原文件一致）
      + 'function renderImage(path){'
      + 'var old=document.getElementById("dsh-filefix");if(old&&old.parentNode)old.parentNode.removeChild(old);'
      + 'var dk=dark();'
      + 'var bg=dk?"#151517":"#ffffff",fg=dk?"#e6e6e9":"#1f1f1f",bd=dk?"#2e2e34":"#e5e5e5",'
      + 'hb=dk?"#1b1b1c":"#f9fafb",sub=dk?"#a6a6ae":"#6b6b6b",bt=dk?"#26262b":"#f2f3f5";'
      + 'var mono="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";'
      + 'var abs=absOf(path)||path;'
      + 'var w=document.createElement("div");w.id="dsh-filefix";'
      + 'w.style.cssText="position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;background:"+bg+";color:"+fg+";display:flex;flex-direction:column;";'
      + 'var bar=document.createElement("div");'
      + 'bar.style.cssText="display:flex;align-items:center;gap:6px;padding:8px 10px;border-bottom:1px solid "+bd+";background:"+hb+";flex:0 0 auto;flex-wrap:wrap;";'
      + 'var pth=document.createElement("div");pth.textContent=abs;'
      + 'pth.style.cssText="flex:1;min-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px;color:"+sub+";font-family:"+mono+";";'
      + 'function mkbtn(label,on){var b=document.createElement("button");b.textContent=label;'
      + 'b.style.cssText="border:1px solid "+bd+";background:"+bt+";color:"+fg+";border-radius:7px;padding:5px 10px;font-size:12.5px;white-space:nowrap;";'
      + 'b.onclick=on;return b;}'
      + 'var body=document.createElement("div");'
      + 'body.style.cssText="flex:1;overflow:auto;-webkit-overflow-scrolling:touch;display:flex;background:"+(dk?"#0e0e10":"#f1f2f4")+";";'
      + 'var img=document.createElement("img");'
      // margin:auto 让它小于容器时居中、大于容器时从左上开始且能完整滚动（display:flex 下必须这样）
      + 'img.style.cssText="display:block;margin:auto;transform-origin:0 0;max-width:none;max-height:none;";'
      + 'img.src="/api/file?path="+encodeURIComponent(abs);'
      + 'body.appendChild(img);'
      + 'var zoom=1,fit=1,nw=0,nh=0;'
      + 'function apply(){img.style.width=(nw*zoom)+"px";img.style.height=(nh*zoom)+"px";}'
      + 'function setZoom(z){zoom=Math.max(0.05,Math.min(20,z));apply();}'
      + 'function fitTo(){fit=(nw&&nh&&body.clientWidth&&body.clientHeight)?Math.min(body.clientWidth/nw,body.clientHeight/nh):1;setZoom(fit);}'
      + 'img.onload=function(){nw=img.naturalWidth||1;nh=img.naturalHeight||1;fitTo();};'
      + 'img.onerror=function(){pth.textContent="（图片加载失败）"+abs;};'
      // 双击：放大到 2.5 倍适应值 ↔ 还原适应
      + 'var lastTap=0;'
      + 'body.addEventListener("click",function(){var tt=Date.now();'
      + 'if(tt-lastTap<320){setZoom(Math.abs(zoom-fit)<0.01?fit*2.5:fit);lastTap=0;}else{lastTap=tt;}});'
      // 双指缩放
      + 'function dist(ts){var dx=ts[0].clientX-ts[1].clientX,dy=ts[0].clientY-ts[1].clientY;return Math.sqrt(dx*dx+dy*dy);}'
      + 'var pinch=null;'
      + 'body.addEventListener("touchstart",function(e){if(e.touches.length===2){pinch={d:dist(e.touches),z:zoom};}},{passive:true});'
      + 'body.addEventListener("touchmove",function(e){if(pinch&&e.touches.length===2){e.preventDefault();'
      + 'if(pinch.d>0)setZoom(pinch.z*dist(e.touches)/pinch.d);}},{passive:false});'
      + 'body.addEventListener("touchend",function(e){if(e.touches.length<2)pinch=null;},{passive:true});'
      + 'bar.appendChild(pth);'
      + 'bar.appendChild(mkbtn("－",function(){setZoom(zoom/1.25);}));'
      + 'bar.appendChild(mkbtn("＋",function(){setZoom(zoom*1.25);}));'
      + 'bar.appendChild(mkbtn("适应屏幕",fitTo));'
      + 'bar.appendChild(mkbtn("原始大小",function(){setZoom(1);}));'
      + 'bar.appendChild(mkbtn("关闭",close));'
      + 'w.appendChild(bar);w.appendChild(body);'
      + 'document.body.appendChild(w);'
      + 'if(!shown){shown=true;try{window.dshShell.setFileFix(1);}catch(e){}}}'
      // 从候选里挑一个"图片"路径
      // 面板里"正在显示图片"的绝对路径 —— 用于**主动接管图片**。
      // 起因：官方图片查看器能显示成功（没有报错），所以"按报错触发"根本轮不到我，
      // 而官方那个**不能放大**。所以图片改为按"面板出现图片"触发。
      // ── office / pdf：本查看器不渲染，交给**系统应用**打开 ─────────────
      // 背景（真机实测）：DSH 的 docx/xlsx/pptx/pdf 渲染器在 ArkWeb 里起不来，
      //   报的是「预览器 xxx 不可用」——注意这**不是**"文件资源服务不可用"，
      //   说明**取字节那条路是通的，失败的是渲染器本身**。
      //   所以"交还官方"对这几类是死路，只能由本 App 转交系统应用打开。
      + 'function isDoc(p){return /[.](docx?|xlsx?|pptx?|odt|ods|odp|rtf|pdf)$/i.test(String(p||""));}'
      // 类型判定**不依赖 errTabName()**（实测它会返回空 —— 正是 office 被误当文本铺出来的元凶）。
      // 改为把能看到的线索全收集起来判一遍：页签标题、路径标签、点击记录。
      + 'function typeOf(){var c=[];try{'
      + 'var tb=document.querySelectorAll("[data-dockkit-tab]");'
      + 'for(var i=0;i<tb.length;i++)c.push((tb[i].innerText||"").trim());}catch(e){}'
      + 'try{var l=document.querySelectorAll("[data-path-label]");'
      + 'for(var j=0;j<l.length;j++)c.push((l[j].innerText||"").trim());}catch(e){}'
      + 'if(lastPath)c.push(lastPath);if(lastUsed)c.push(lastUsed);'
      + 'for(var k=0;k<c.length;k++){var s=c[k];if(!s)continue;'
      + 'if(isDoc(s))return s;}return null;}'
      // office/pdf 的占位页：文件名 + 类型 + 「用系统应用打开」
      + 'function renderOpenWith(path){'
      + 'var old=document.getElementById("dsh-filefix");if(old&&old.parentNode)old.parentNode.removeChild(old);'
      + 'var dk=dark();'
      + 'var bg=dk?"#151517":"#ffffff",fg=dk?"#e6e6e9":"#1f1f1f",bd=dk?"#2e2e34":"#e5e5e5",'
      + 'sub=dk?"#a6a6ae":"#6b6b6b",bt=dk?"#26262b":"#f2f3f5",ac=dk?"#4c8dff":"#2f6fed";'
      + 'var abs=absOf(path)||path;var nm=base(abs);var ext=(nm.split(".").pop()||"").toUpperCase();'
      + 'var w=document.createElement("div");w.id="dsh-filefix";'
      + 'w.style.cssText="position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;background:"+bg+";color:"+fg+";display:flex;flex-direction:column;";'
      + 'var bar=document.createElement("div");'
      + 'bar.style.cssText="display:flex;align-items:center;gap:6px;padding:8px 10px;border-bottom:1px solid "+bd+";flex:0 0 auto;flex-wrap:wrap;";'
      + 'var pth=document.createElement("div");pth.textContent=abs;'
      + 'pth.style.cssText="flex:1;min-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px;color:"+sub+";";'
      + 'var cb=document.createElement("button");cb.textContent="关闭";'
      + 'cb.style.cssText="border:1px solid "+bd+";background:"+bt+";color:"+fg+";border-radius:7px;padding:5px 10px;font-size:12.5px;";'
      + 'cb.onclick=close;bar.appendChild(pth);bar.appendChild(cb);'
      + 'var body=document.createElement("div");'
      + 'body.style.cssText="flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px;text-align:center;";'
      + 'var ic=document.createElement("div");ic.textContent=ext;'
      + 'ic.style.cssText="width:96px;height:96px;border-radius:14px;border:2px solid "+ac+";color:"+ac+";display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:700;";'
      + 'var t1=document.createElement("div");t1.textContent=nm;t1.style.cssText="font-size:15px;font-weight:600;word-break:break-all;max-width:80%;";'
      + 'var t2=document.createElement("div");t2.textContent="这种格式本查看器不渲染，交给手机上的应用打开";'
      + 't2.style.cssText="font-size:12.5px;color:"+sub+";max-width:80%;line-height:1.6;";'
      + 'var ob=document.createElement("button");ob.textContent="用系统应用打开";'
      + 'ob.style.cssText="border:none;background:"+ac+";color:#fff;border-radius:10px;padding:12px 26px;font-size:15px;font-weight:600;";'
      + 'function mimeOf(n){var e=(String(n).split(".").pop()||"").toLowerCase();'
      + 'var m={doc:"application/msword",docx:"application/vnd.openxmlformats-officedocument.wordprocessingml.document",'
      + 'xls:"application/vnd.ms-excel",xlsx:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",'
      + 'ppt:"application/vnd.ms-powerpoint",pptx:"application/vnd.openxmlformats-officedocument.presentationml.presentation",'
      + 'pdf:"application/pdf",odt:"application/vnd.oasis.opendocument.text",'
      + 'ods:"application/vnd.oasis.opendocument.spreadsheet",odp:"application/vnd.oasis.opendocument.presentation",'
      + 'rtf:"application/rtf"};return m[e]||"application/octet-stream";}'
      + 'ob.onclick=function(){ob.textContent="正在准备…";ob.disabled=true;'
      // 把"完整下载地址 + 文件名 + MIME"交给原生：原生就不必猜基址，也不用搬 base64
      + 'try{window.dshShell.openFile(JSON.stringify({'
      + 'url:location.origin+"/api/file?path="+encodeURIComponent(abs),'
      + 'name:nm,mime:mimeOf(nm)}));}catch(e){}'
      + 'setTimeout(function(){ob.textContent="用系统应用打开";ob.disabled=false;},2500);};'
      + 'body.appendChild(ic);body.appendChild(t1);body.appendChild(t2);body.appendChild(ob);'
      + 'w.appendChild(bar);w.appendChild(body);document.body.appendChild(w);'
      + 'if(!shown){shown=true;try{window.dshShell.setFileFix(1);}catch(e){}}}'
      // ★只认**右侧栏里**的图片 —— 聊天里内联的图片（消息缩略图）绝不能触发。
      // 【踩过的坑】第一版优先匹配 src 含 /api/file?path= 的 <img>，
      //   而**聊天内联图正是这种 src**，真正的预览反而是 blob:
      //   → 展开一条含图的消息会莫名弹出查看器；关掉查看器后又会命中下一条内联图。
      // 现在改为：① 只在 [data-dockkit-content]（右侧栏页签内容）里找
      //           ② 排除小图（图标/头像，naturalWidth < 160）
      //           ③ 优先 blob:（官方就是取字节造 blob），路径从页签标签取
      + 'function activeImagePath(){try{'
      + 'var panes=document.querySelectorAll("[data-dockkit-content]");'
      + 'for(var pi=panes.length-1;pi>=0;pi--){var P=panes[pi];'
      + 'var r0=P.getBoundingClientRect();if(!(r0.width>0&&r0.height>0))continue;'
      + 'var ims=P.querySelectorAll("img");'
      + 'for(var i=ims.length-1;i>=0;i--){var im=ims[i];'
      + 'if((im.naturalWidth||0)<160)continue;'
      + 'var r=im.getBoundingClientRect();if(!(r.width>80&&r.height>80))continue;'
      + 'var s=im.getAttribute("src")||"";'
      + 'if(s.indexOf("blob:")===0){'
      + 'var l=document.querySelectorAll("[data-path-label]");'
      + 'for(var j=l.length-1;j>=0;j--){var tt=(l[j].innerText||"").trim();'
      + 'if(isImg(tt))return {path:tt,pane:P};}}'
      + 'var m=s.match(/[?&]path=([^&]+)/);'
      + 'if(m){try{return {path:decodeURIComponent(m[1]),pane:P};}catch(e){}}'
      // ⚠️ 这里要 **3 个**右花括号：已开的块是 for(pi) / for(i) / 以及最外层的 try，
      //    关掉这三个之后紧接的 catch 才是 try 的。
      //    （本次为这个花括号数错了两次：errTabName 和多一个、这里和 closePane 各错一次；
      //      **别靠肉眼数，抽出来 node --check，并用脚本打印每个 try 的配平位置**。）
      + '}}}catch(e){}return null;}'
      // 关掉"官方那个图片预览页签" —— 从页签内容容器拿到 tabN，再点它的关闭按钮。
      // 这样只留本查看器一层（用户反馈：原来官方一层 + 我这一层，关掉我的官方还在）。
      // 关掉官方那个"预览器不可用"的页签（office/pdf 接管后调用），避免"关了我的官方还在"
      + 'function closeOfficialTab(){try{return closeErrTab();}catch(e){return false;}}'
      + 'function closePane(pane){try{var n=pane,d=0;'
      + 'while(n&&n!==document&&d<6){d++;'
      + 'if(n.getAttribute){var id=n.getAttribute("data-dockkit-content");'
      + 'if(id){var cb=document.querySelector("[data-dockkit-tab-close=\\""+id+"\\"]");'
      + 'if(cb){cb.click();return true;}}}}'
      // ⚠️ 这里只 **1 个**右花括号：上面 `if(cb){…}}}}` 已经把 while 也关掉了
      //    （它是**有块**的 if，比无块的写法多开一个），所以只需 1 个关 try。
      //    写 2 个会把 function 一起关掉，catch 就悬空了。
      + 'n=n.parentElement;}catch(e){}return false;}'
      + 'function imgCandidate(){var l=candidates();'
      + 'for(var i=0;i<l.length;i++){if(isImg(l[i]))return l[i];}return null;}'
      + 'function dark(){try{var el=document.querySelector("[class*=sidebarCol]")||document.body;'
      + 'var n=el,d=0,c=null;while(n&&n!==document.documentElement&&d<12){d++;'
      + 'var x=getComputedStyle(n).backgroundColor;'
      + 'if(x&&x!=="rgba(0, 0, 0, 0)"&&x!=="transparent"){c=x;break;}n=n.parentElement;}'
      + 'var m=c&&c.match(/(\\d+),\\s*(\\d+),\\s*(\\d+)/);if(!m)return false;'
      + 'return (0.299*(+m[1])+0.587*(+m[2])+0.114*(+m[3]))/255<0.5;}catch(e){return false;}}'
      // ── Markdown 渲染（自写轻量实现，无外部依赖）──
      + 'function mdEsc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}'
      + 'function mdInline(s){'
      + 's=mdEsc(s);'
      + 's=s.replace(/`([^`]+)`/g,function(m,a){return "<code>"+a+"</code>";});'
      + 's=s.replace(/!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)/g,function(m,alt,url){'
      + 'if(/^https?:\\/\\//i.test(url))return "<img src=\\""+url+"\\" alt=\\""+alt+"\\">";'
      + 'return "<span class=\\"md-img\\">[图片] "+alt+" ("+url+")</span>";});'
      + 's=s.replace(/\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)/g,function(m,txt,url){'
      + 'return "<a href=\\""+url+"\\" title=\\""+url+"\\">"+txt+"</a>";});'
      + 's=s.replace(/\\*\\*([^*]+)\\*\\*/g,"<strong>$1</strong>");'
      + 's=s.replace(/__([^_]+)__/g,"<strong>$1</strong>");'
      + 's=s.replace(/~~([^~]+)~~/g,"<del>$1</del>");'
      + 's=s.replace(/(^|[^*])\\*([^*\\n]+)\\*/g,"$1<em>$2</em>");'
      + 's=s.replace(/(^|[^_])_([^_\\n]+)_/g,"$1<em>$2</em>");'
      + 'return s;}'
      + 'function mdRow(l){return l.replace(/^\\s*\\|/,"").replace(/\\|\\s*$/,"").split("|").map(function(x){return x.trim();});}'
      + 'function mdToHtml(src){'
      + 'var lines=String(src).split("\\n"),out=[],i=0;'
      + 'while(i<lines.length){var ln=lines[i];'
      // 代码围栏
      + 'var f=ln.match(/^\\s*(`{3,}|~{3,})\\s*([\\w+#-]*)\\s*$/);'
      + 'if(f){var ch=f[1].charAt(0),lang=f[2]||"",buf=[];i++;'
      + 'while(i<lines.length&&lines[i].indexOf(ch+ch+ch)<0){buf.push(lines[i]);i++;}'
      + 'i++;'
      + 'out.push("<pre class=\\"md-code\\" data-lang=\\""+mdEsc(lang)+"\\"><code>"+mdEsc(buf.join("\\n"))+"</code></pre>");continue;}'
      // 标题
      + 'var h=ln.match(/^(#{1,6})\\s+(.*)$/);'
      + 'if(h){var lv=h[1].length;out.push("<h"+lv+">"+mdInline(h[2])+"</h"+lv+">");i++;continue;}'
      // 分隔线
      + 'if(/^\\s*([-*_])\\s*\\1\\s*\\1[-\\s*_]*$/.test(ln)){out.push("<hr>");i++;continue;}'
      // 引用块
      + 'if(/^\\s*>/.test(ln)){var qb=[];'
      + 'while(i<lines.length&&/^\\s*>/.test(lines[i])){qb.push(lines[i].replace(/^\\s*>\\s?/,""));i++;}'
      + 'out.push("<blockquote>"+mdToHtml(qb.join("\\n"))+"</blockquote>");continue;}'
      // 表格
      + 'if(ln.indexOf("|")>=0&&i+1<lines.length&&/^\\s*\\|?[\\s:|-]+\\|[\\s:|-]*$/.test(lines[i+1])&&lines[i+1].indexOf("-")>=0){'
      + 'var hd=mdRow(ln);i+=2;var rows=[];'
      + 'while(i<lines.length&&lines[i].indexOf("|")>=0&&lines[i].trim()!==""){rows.push(mdRow(lines[i]));i++;}'
      + 'var t="<table><thead><tr>",c1;'
      + 'for(c1=0;c1<hd.length;c1++)t+="<th>"+mdInline(hd[c1])+"</th>";'
      + 't+="</tr></thead><tbody>";'
      + 'for(var r1=0;r1<rows.length;r1++){t+="<tr>";'
      + 'for(c1=0;c1<hd.length;c1++)t+="<td>"+mdInline(rows[r1][c1]||"")+"</td>";t+="</tr>";}'
      + 'out.push(t+"</tbody></table>");continue;}'
      // 列表
      + 'if(/^\\s*([-*+]|\\d+[.)])\\s+/.test(ln)){'
      + 'var ord=/^\\s*\\d+[.)]\\s+/.test(ln),its=[];'
      + 'while(i<lines.length&&/^\\s*([-*+]|\\d+[.)])\\s+/.test(lines[i])){'
      + 'its.push(lines[i].replace(/^\\s*([-*+]|\\d+[.)])\\s+/,""));i++;}'
      + 'var lt=ord?"ol":"ul",ls="<"+lt+">";'
      + 'for(var k1=0;k1<its.length;k1++)ls+="<li>"+mdInline(its[k1])+"</li>";'
      + 'out.push(ls+"</"+lt+">");continue;}'
      // 空行
      + 'if(/^\\s*$/.test(ln)){i++;continue;}'
      // 段落
      + 'var pb=[];'
      + 'while(i<lines.length&&!/^\\s*$/.test(lines[i])'
      + '&&!/^\\s*(#{1,6}\\s|>|([-*+]|\\d+[.)])\\s)/.test(lines[i])'
      + '&&!/^\\s*(`{3,}|~{3,})/.test(lines[i])){pb.push(lines[i]);i++;}'
      // ★先逐行转义再拼 <br>。若写成 mdInline(pb.join("<br>"))，
      //   mdInline 开头的转义会把刚拼的 <br> 也转义掉，页面上就会看到字面的 "<br>"（踩过）。
      + 'out.push("<p>"+pb.map(mdInline).join("<br>")+"</p>");}'
      + 'return out.join("\\n");}'
      // 查看器内的样式（作用域限定在 #dsh-filefix 内）
      + 'function css(dk){var bd=dk?"#2e2e34":"#e5e5e5",sub=dk?"#a6a6ae":"#6b6b6b",'
      + 'cb=dk?"#1b1b1c":"#f6f7f9",lnk=dk?"#8fb6ff":"#1a4fb4",qt=dk?"#9aa0a6":"#6b6b6b";'
      + 'return "#dsh-filefix .md{font-size:14px;line-height:1.75;word-break:break-word;}"'
      + '+ "#dsh-filefix .md h1,#dsh-filefix .md h2,#dsh-filefix .md h3,#dsh-filefix .md h4{margin:18px 0 10px;line-height:1.35;font-weight:600;}"'
      + '+ "#dsh-filefix .md h1{font-size:22px;border-bottom:1px solid "+bd+";padding-bottom:8px;}"'
      + '+ "#dsh-filefix .md h2{font-size:19px;border-bottom:1px solid "+bd+";padding-bottom:6px;}"'
      + '+ "#dsh-filefix .md h3{font-size:16px;}"'
      + '+ "#dsh-filefix .md h4,#dsh-filefix .md h5,#dsh-filefix .md h6{font-size:14px;}"'
      + '+ "#dsh-filefix .md p{margin:10px 0;}"'
      + '+ "#dsh-filefix .md ul,#dsh-filefix .md ol{margin:10px 0;padding-left:24px;}"'
      + '+ "#dsh-filefix .md li{margin:4px 0;}"'
      + '+ "#dsh-filefix .md code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;'
      + 'background:"+cb+";padding:1px 5px;border-radius:4px;}"'
      + '+ "#dsh-filefix .md pre.md-code{background:"+cb+";border:1px solid "+bd+";border-radius:8px;'
      + 'padding:10px 12px;overflow:auto;margin:12px 0;}"'
      + '+ "#dsh-filefix .md pre.md-code code{background:none;padding:0;font-size:12.5px;line-height:1.55;}"'
      + '+ "#dsh-filefix .md blockquote{margin:12px 0;padding:2px 0 2px 12px;border-left:3px solid "+bd+";color:"+qt+";}"'
      + '+ "#dsh-filefix .md hr{border:none;border-top:1px solid "+bd+";margin:18px 0;}"'
      + '+ "#dsh-filefix .md a{color:"+lnk+";text-decoration:none;border-bottom:1px solid "+lnk+";}"'
      + '+ "#dsh-filefix .md table{border-collapse:collapse;margin:12px 0;font-size:13px;display:block;overflow-x:auto;}"'
      + '+ "#dsh-filefix .md th,#dsh-filefix .md td{border:1px solid "+bd+";padding:6px 10px;text-align:left;}"'
      + '+ "#dsh-filefix .md th{background:"+cb+";font-weight:600;}"'
      + '+ "#dsh-filefix .md img{max-width:100%;border-radius:6px;}"'
      + '+ "#dsh-filefix .md .md-img{color:"+sub+";font-size:12px;}";}'
      // ── 关掉"显示着错误"的那个页签 ──
      + 'function closeErrTab(){try{'
      + 'var ers=document.querySelectorAll("[data-textpreview-state=loading]");'
      + 'for(var i=0;i<ers.length;i++){var n=ers[i],d=0;'
      + 'while(n&&n!==document&&d<24){d++;'
      + 'if(n.getAttribute){var id=n.getAttribute("data-dockkit-content");'
      + 'if(id){var cb=document.querySelector("[data-dockkit-tab-close=\\""+id+"\\"]");'
      + 'if(cb){cb.click();return true;}}}'
      + 'n=n.parentElement;}}}catch(e){}return false;}'
      // 按文件名兜底：只在 dock 页签里找（别用 [aria-selected=true]，会认错目标）
      + 'function closeDshTab(name){try{if(!name)return false;'
      + 'var ts=document.querySelectorAll("[data-dockkit-tab]"),cand=null,i,t;'
      + 'for(i=0;i<ts.length;i++){t=(ts[i].innerText||"").trim();if(t===name){cand=ts[i];break;}}'
      + 'if(!cand){for(i=0;i<ts.length;i++){t=(ts[i].innerText||"").trim();'
      + 'if(t&&(name.indexOf(t)>=0||t.indexOf(name)>=0)){cand=ts[i];break;}}}'
      + 'if(!cand)return false;'
      + 'var id=cand.getAttribute("data-dockkit-tab");'
      + 'if(id){var cb=document.querySelector("[data-dockkit-tab-close=\\""+id+"\\"]");if(cb){cb.click();return true;}}'
      + '}catch(e){}return false;}'
      + 'function rd(path,offset,cb){var sc=getScope();'
      + 'if(!sc){cb(null);return;}'
      + 'var body=JSON.stringify({type:"client-request",rpcId:"ff-"+Date.now()+"-"+Math.random().toString(36).slice(2),'
      + 'method:"workspaceFiles/read",payload:{args:{workspaceFileScopeId:sc,path:path,range:{offset:offset,limit:2000}}}});'
      + 'fetch("/api/workspaceFiles/read",{method:"POST",headers:{"Content-Type":"application/json"},credentials:"include",body:body})'
      + '.then(function(r){return r.json();})'
      + '.then(function(j){var v=j&&j.result&&j.result.value;cb(v||null);})'
      + '.catch(function(e){cb(null);});}'
      + 'function close(){var o=document.getElementById("dsh-filefix");'
      + 'if(o&&o.parentNode)o.parentNode.removeChild(o);'
      + 'if(shown){shown=false;try{window.dshShell.setFileFix(0);}catch(e){}}'
      // 关闭查看器时把原版那个报错页签也一并收掉
      + 'closeErrTab();if(lastUsed)closeDshTab(base(lastUsed));'
      + 'setTimeout(function(){closeErrTab();if(lastUsed)closeDshTab(base(lastUsed));},350);}'
      + 'window.__dshCloseFileFix=close;'
      // ── 渲染 ──
      + 'function render(v,path){'
      + 'var old=document.getElementById("dsh-filefix");if(old&&old.parentNode)old.parentNode.removeChild(old);'
      + 'var dk=dark();'
      + 'var bg=dk?"#151517":"#ffffff",fg=dk?"#e6e6e9":"#1f1f1f",bd=dk?"#2e2e34":"#e5e5e5",'
      + 'hb=dk?"#1b1b1c":"#f9fafb",sub=dk?"#a6a6ae":"#6b6b6b",bt=dk?"#26262b":"#f2f3f5";'
      + 'var mono="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";'
      + 'var raw=(v&&typeof v.text==="string")?v.text:"（读取失败）";'
      + 'var name=base(path||"");'
      // 默认：.md/.markdown 用 Markdown 渲染，其余纯文本
      + 'var md=/[.](md|markdown|mdx)$/i.test(name);'
      + 'var wrapped=true;'
      + 'var st=document.createElement("style");st.textContent=css(dk);'
      + 'var w=document.createElement("div");w.id="dsh-filefix";'
      + 'w.style.cssText="position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;background:"+bg+";color:"+fg+";display:flex;flex-direction:column;";'
      + 'w.appendChild(st);'
      + 'var bar=document.createElement("div");'
      + 'bar.style.cssText="display:flex;align-items:center;gap:8px;padding:9px 12px;border-bottom:1px solid "+bd+";background:"+hb+";flex:0 0 auto;";'
      + 'var pth=document.createElement("div");pth.textContent=(v&&v.absolutePath)||path||"";'
      + 'pth.style.cssText="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px;color:"+sub+";font-family:"+mono+";";'
      + 'function mkbtn(label,on){var b=document.createElement("button");b.textContent=label;'
      + 'b.style.cssText="border:1px solid "+bd+";background:"+bt+";color:"+fg+";border-radius:7px;padding:5px 11px;font-size:12.5px;white-space:nowrap;";'
      + 'b.onclick=on;return b;}'
      + 'var body=document.createElement("div");'
      + 'body.style.cssText="flex:1;overflow:auto;";'
      + 'var pre=document.createElement("pre");'
      + 'pre.style.cssText="margin:0;padding:12px 14px;white-space:pre-wrap;word-break:break-word;font-family:"+mono+";font-size:12.5px;line-height:1.65;";'
      + 'body.appendChild(pre);'
      // 按模式刷新正文（Markdown 用 .md 容器另起一个 div）
      + 'var mdBox=null;'
      + 'function paint(){'
      + 'if(md){'
      + 'if(!mdBox){mdBox=document.createElement("div");mdBox.className="md";'
      + 'mdBox.style.cssText="padding:12px 14px;";body.appendChild(mdBox);}'
      + 'pre.style.display="none";mdBox.style.display="block";'
      + 'mdBox.innerHTML=mdToHtml(raw);'
      + '}else{'
      + 'if(mdBox)mdBox.style.display="none";'
      + 'pre.style.display="block";pre.textContent=raw;}'
      + 'syncView();}'
      + 'var wrapBtn=mkbtn("",function(){wrapped=!wrapped;'
      + 'pre.style.whiteSpace=wrapped?"pre-wrap":"pre";pre.style.wordBreak=wrapped?"break-word":"normal";'
      + 'pre.style.overflowX=wrapped?"hidden":"auto";syncView();});'
      + 'var viewBtn=mkbtn("",function(){md=!md;paint();});'
      + 'var reBtn=mkbtn("重新读取",function(){raw="读取中…";paint();'
      + 'rd(path,1,function(v2){if(!v2){raw="（读取失败）";paint();return;}'
      + 'raw=typeof v2.text==="string"?v2.text:"（读取失败）";'
      + 'pth.textContent=v2.absolutePath||path;paint();});});'
      + 'var clBtn=mkbtn("关闭",close);'
      // 按钮状态用文字表达（只靠颜色深浅用户看不出 —— 踩过）
      + 'function syncView(){'
      + 'viewBtn.textContent=md?"Markdown":"纯文本";'
      + 'viewBtn.style.background=md?(dk?"#182740":"#eaf1ff"):bt;'
      + 'viewBtn.style.borderColor=md?(dk?"#2b4a7a":"#b9cdf0"):bd;'
      + 'viewBtn.style.color=md?(dk?"#8fb6ff":"#1a4fb4"):sub;'
      + 'wrapBtn.style.display=md?"none":"";'
      + 'wrapBtn.textContent=wrapped?"自动换行":"取消换行";'
      + 'wrapBtn.style.background=wrapped?(dk?"#182740":"#eaf1ff"):bt;'
      + 'wrapBtn.style.borderColor=wrapped?(dk?"#2b4a7a":"#b9cdf0"):bd;'
      + 'wrapBtn.style.color=wrapped?(dk?"#8fb6ff":"#1a4fb4"):sub;}'
      + 'bar.appendChild(pth);bar.appendChild(viewBtn);bar.appendChild(wrapBtn);bar.appendChild(reBtn);bar.appendChild(clBtn);'
      + 'w.appendChild(bar);w.appendChild(body);'
      + 'paint();'
      // 加载更多：按原始文本追加后重新渲染
      + 'if(v&&v.eof===false){var ft=document.createElement("div");'
      + 'ft.style.cssText="flex:0 0 auto;padding:9px;text-align:center;border-top:1px solid "+bd+";background:"+hb+";";'
      + 'var mb=mkbtn("加载更多",function(){mb.disabled=true;mb.textContent="加载中…";'
      + 'var off=(v.offset||1)+(v.lines||0);'
      + 'rd(path,off,function(v2){mb.disabled=false;mb.textContent="加载更多";'
      + 'if(!v2||typeof v2.text!=="string")return;raw=raw+v2.text;'
      + 'v.offset=v2.offset;v.lines=v2.lines;v.eof=v2.eof;paint();});});'
      + 'ft.appendChild(mb);w.appendChild(ft);}'
      // 链接不跳转（否则 WebView 会离开 DSH 页面）
      + 'w.addEventListener("click",function(e){var n=e.target;'
      + 'while(n&&n!==w){if(n.tagName==="A"){e.preventDefault();return;}n=n.parentElement;}},true);'
      // 侧滑关闭：只认从左边缘起滑
      + 'var sx=null,sy=null;'
      + 'w.addEventListener("touchstart",function(e){var t=e.touches[0];sx=t.clientX;sy=t.clientY;},{passive:true});'
      + 'w.addEventListener("touchend",function(e){if(sx===null)return;var t=e.changedTouches[0];'
      + 'var dx=t.clientX-sx,dy=t.clientY-sy;var fromEdge=(sx<56);sx=null;'
      + 'if(fromEdge&&dx>70&&Math.abs(dy)<70){close();}},{passive:true});'
      + 'document.body.appendChild(w);'
      + 'if(!shown){shown=true;try{window.dshShell.setFileFix(1);}catch(e){}}}'
      // 候选路径：全部收集（去重）
      + 'function candidates(){var out=[],seen={};'
      + 'function push(p){if(!p)return;p=String(p).trim();if(!p||seen[p])return;seen[p]=1;out.push(p);}'
      + 'try{var els=document.querySelectorAll("[data-path-label]");'
      + 'for(var i=0;i<els.length;i++){var t=(els[i].innerText||"").trim();'
      + 'if(t&&(t.indexOf("/")>=0||t.indexOf("\\\\")>=0))push(t);}}catch(e){}'
      + 'try{var us=document.querySelectorAll("[data-textpreview-url]");'
      + 'for(i=0;i<us.length;i++){var u=us[i].getAttribute("data-textpreview-url")||"";'
      + 'var m=u.match(/\\/session\\/[^\\/]+\\/(.+)$/);'
      + 'if(m){try{push(decodeURIComponent(m[1]));}catch(e2){}}}}catch(e){}'
      + 'push(lastPath);'
      + 'try{var ts=document.querySelectorAll("[data-dockkit-tab]");'
      + 'for(i=0;i<ts.length;i++){var nm=(ts[i].innerText||"").trim();'
      + 'if(nm&&nm.indexOf(".")>0&&nm.length<80)push(nm);}}catch(e){}'
      + 'return out;}'
      // 逐个试读，取第一个成功的
      + 'function tryAll(list,idx,cb){'
      + 'if(!list||idx>=list.length){cb(null,null);return;}'
      + 'rd(list[idx],1,function(v){'
      + 'if(v&&typeof v.text==="string"){cb(v,list[idx]);}'
      + 'else{tryAll(list,idx+1,cb);}});}'
      // 全失败：把"看到了什么"显示出来，便于截图定位
      + 'function showDiag(list){var lines=[];'
      + 'lines.push("无法确定要读哪个文件。请把本页截图发给 AI。");lines.push("");'
      + 'lines.push("会话标识 scope = "+(getScope()||"（空）"));'
      + 'lines.push("尝试过的候选路径（"+list.length+" 个）：");'
      + 'for(var i=0;i<list.length;i++)lines.push("  "+i+". "+list[i]);'
      + 'try{var els=document.querySelectorAll("[data-path-label]");'
      + 'lines.push("");lines.push("[data-path-label] 共 "+els.length+" 个：");'
      + 'for(i=0;i<els.length;i++)lines.push("  · "+(els[i].innerText||"").trim());}catch(e){}'
      + 'try{var ts=document.querySelectorAll("[data-dockkit-tab]");'
      + 'lines.push("");lines.push("页签："+Array.prototype.map.call(ts,function(t){return (t.innerText||"").trim();}).join(" | "));}catch(e){}'
      + 'render({text:lines.join("\\n"),absolutePath:"诊断"},null);}'
      + 'function show(path,preset){'
      // 图片：直接走图片查看器（不调 read —— 二进制读不出文本）
      + 'var ip=(path&&isImg(path))?path:imgCandidate();'
      + 'if(ip){lastUsed=ip;renderImage(ip);'
      + 'closeErrTab();closeDshTab(base(ip));'
      + 'setTimeout(function(){closeErrTab();closeDshTab(base(ip));},350);return;}'
      + 'var done=function(v,used){if(v){lastUsed=used||path;render(v,lastUsed);'
      + 'closeErrTab();closeDshTab(base(lastUsed));'
      + 'setTimeout(function(){closeErrTab();closeDshTab(base(lastUsed));},350);}'
      + 'else{showDiag(candidates());}};'
      + 'if(preset&&prefetch){var pv=prefetch;prefetch=null;done(pv,path);return;}'
      + 'if(path){done(null,path);rd(path,1,function(v){done(v,path);});return;}'
      + 'var list=candidates();'
      + 'if(!list.length){showDiag(list);return;}'
      + 'tryAll(list,0,done);}'
      // 取"正在显示错误的那个页签"的标题 —— 即出错的文件名。
      // 用于判断类型：从错误元素往上找 data-dockkit-content 拿页签 id，再读该页签标题。
      + 'function errTabName(){try{'
      + 'var ers=document.querySelectorAll("[data-textpreview-state=loading]");'
      + 'for(var i=0;i<ers.length;i++){var r=ers[i].getBoundingClientRect();'
      + 'if(!(r.width>0&&r.height>0))continue;'
      + 'if((ers[i].innerText||"").indexOf("不可用")<0)continue;'
      + 'var n=ers[i],d=0;'
      + 'while(n&&n!==document&&d<24){d++;'
      + 'if(n.getAttribute){var id=n.getAttribute("data-dockkit-content");'
      + 'if(id){var tb=document.querySelector("[data-dockkit-tab=\\""+id+"\\"]");'
      + 'if(tb)return (tb.innerText||"").trim();}}}'
      // ⚠️ 这里结束 try 只要 2 个右花括号：上面 `if(tb)return …` **没有花括号**，
      //    所以 `}}}` 已经把 while/if(id)/if(getAttribute) 都关了，
      //    再多一个就会把 try 也关掉、让 catch 悬空（整段脚本解析失败 → 查看器全废）。
      //    踩过：编译期发现不了（ArkTS 不校验注入的 JS 字符串），
      //    靠"抽出真代码 + node --check"才查出来。
      + 'n=n.parentElement;}}catch(e){}return "";}'
      + 'function findErr(){try{var ds=document.querySelectorAll("[data-textpreview-state=loading]");'
      + 'for(var i=0;i<ds.length;i++){var r=ds[i].getBoundingClientRect();'
      + 'if(r.width>0&&r.height>0&&(ds[i].innerText||"").indexOf("不可用")>=0)return true;}}catch(e){}return false;}'
      + 'function watchFast(){if(timer)clearInterval(timer);var n=0;'
      + 'timer=setInterval(function(){n++;'
      + 'if(findErr()&&lastPath&&!shown&&!isOtherBin(base(lastPath))){clearInterval(timer);timer=null;show(lastPath,true);return;}'
      + 'if(n>25||document.querySelector("[data-textpreview-state=text]")){clearInterval(timer);timer=null;}},100);}'
      + 'document.addEventListener("click",function(e){try{var n=e.target;while(n&&n!==document){'
      + 'if(n.getAttribute&&n.getAttribute("data-files-entry")==="file"&&n.getAttribute("data-files-path")){'
      + 'lastPath=n.getAttribute("data-files-path");prefetch=null;'
      + 'rd(lastPath,1,function(v){prefetch=v;});'
      + 'watchFast();break;}n=n.parentElement;}}catch(x){}},true);'
      // ★兜底总闸：任何入口触发的错误都接管
      // 接"上下文图片被点击"的通知，**立刻**渲染（文档期脚本拦的，官方不会打开）
      + 'function wantImg(p){try{if(!p||!isImg(p))return;'
      + 'if(p===imgDone)return;imgDone=p;lastUsed=p;renderImage(p);}catch(e){}}'
      + 'try{window.addEventListener("dsh-img-want",function(e){wantImg(e&&e.detail);});}catch(e){}'
      + 'setInterval(function(){try{'
      + 'if(shown)return;'
      // ★图片主动接管：官方图片查看器不能放大，所以图片一律由本查看器渲染（带缩放）。
      //   注意用 imgDone 去重，否则用户关掉浮层后会立刻又被弹出来。
      // office/pdf：先判类型（不看报错态）→ 占位页 + 交系统应用
      + 'var dch=typeOf();'
      + 'if(dch&&!isImg(dch)){var dk2=base(dch);'
      + 'if(dk2!==docDone){docDone=dk2;lastUsed=dch;renderOpenWith(dch);closeOfficialTab();'
      + 'setTimeout(closeOfficialTab,350);}return;}'
      // 兜底：文档期拦下的路径（事件可能因时序没接住）
      + 'if(window.__dshImgWant){var _w=window.__dshImgWant;window.__dshImgWant=null;wantImg(_w);return;}'
      + 'var ir=activeImagePath();'
      + 'if(ir&&ir.path){'
      + 'if(ir.path!==imgDone){imgDone=ir.path;lastUsed=ir.path;renderImage(ir.path);'
      // 接管后**关掉官方那个预览页签**：只留一层，避免"关掉我的官方还在"
      + 'closePane(ir.pane);setTimeout(function(){closePane(ir.pane);},350);}'
      + 'return;}'
      + 'imgDone="";'
      + 'if(!findErr()){errSig="";return;}'
      // 图片之外的二进制（pdf/zip/视频…）：**完全不接管**，交给官方查看器。
      + 'if(isOtherBin(errTabName())){errSig="__bin__";return;}'
      + 'var list=candidates();var sig=list.join("|");'
      + 'if(!list.length){if(errSig!=="__none__"){errSig="__none__";showDiag(list);}return;}'
      + 'if(sig===errSig)return;'
      + 'errSig=sig;show(null,false);'
      + '}catch(e){}},400);'
      + '})()');
  }

  injectAll(): void {
    // 自建文件查看器：始终启用（这是"文件打不开"的兜底，不受诊断开关影响）
   this.injectFileFix();
    if (!this.injectEnabled) {
      return;
    }
    // ① 上报左侧栏宽度 + 网页真实配色（原生状态栏双色块据此上色 → 深色模式自动跟随）
    //    · sidebarCol 的背景色 = 左块颜色
    //    · centerCol 的背景色（继承自 frame）= 右块颜色
    //    · sidebarCol 的 border-right-color 是半透明的 rgba(0,0,0,.12)，
    //      必须与左块底色做 alpha 合成，才能得到可直接使用的实色分界线
    //      （浅色下合成结果正是之前硬编码的 #DBDCDE；深色下会自动变成浅色分界线）
    // ① 已合并进 ⑦（下面）：侧栏宽度/配色、浮层状态统一由一个轮询负责，
    //    避免多个 setInterval 同时做全 DOM 查询把手机主线程拖死。

    // ② 在 DSH 设置弹窗里、Agent 预设右侧插入「站点」选项卡
    this.js('(function(){if(window.__dshSites){return;}window.__dshSites=1;setInterval(function(){try{var d=document.querySelector("[role=dialog]");if(!d){return;}if(d.querySelector("[data-dsh-sites]")){return;}var bs=d.querySelectorAll("button,[role=tab]");var a=null;for(var i=0;i<bs.length;i++){var x=(bs[i].textContent||"").trim();if(x.indexOf("Agent")===0){a=bs[i];break;}}if(!a||!a.parentElement){return;}var b=document.createElement("button");b.type="button";b.setAttribute("data-dsh-sites","1");b.textContent="\u7ad9\u70b9";b.className=a.className;b.style.marginLeft="4px";b.onclick=function(e){e.stopPropagation();window.dshShell.openSites();};a.parentElement.insertBefore(b,a.nextSibling);}catch(e){}},1200);})()');
    // ③ 自动登录：按当前站点的账号密码填表并提交
    this.js('(function(){if(window.__dshLogin){return;}window.__dshLogin=1;function sv(el,v){try{var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value");if(d&&d.set){d.set.call(el,v);}else{el.value=v;}el.dispatchEvent(new Event("input",{bubbles:true}));el.dispatchEvent(new Event("change",{bubbles:true}));}catch(e){}}function go(){try{var c=JSON.parse(window.dshShell.getCurrent()||"{}");var g=JSON.parse(window.dshShell.getGroups()||"[]");var a=(g[c.g]&&g[c.g].items)?g[c.g].items[c.i]:null;if(!a||!a.user||!a.pass){return;}var p=document.querySelector("input[type=password]");if(!p){return;}var sc=p.form||document;var ins=sc.querySelectorAll("input");var u=null;for(var i=0;i<ins.length;i++){var t=(ins[i].type||"text").toLowerCase();if(t==="text"||t==="email"||t==="tel"){u=ins[i];break;}}if(u&&!u.value){sv(u,a.user);}if(!p.value){sv(p,a.pass);}var b=sc.querySelector("button[type=submit],input[type=submit]");if(b){b.click();}else if(p.form){p.form.requestSubmit();}}catch(e){}}setTimeout(go,1500);setTimeout(go,3500);})()');
    // ④ 自动点掉首次引导弹窗（"继续"/"我知道了"/"开始使用"）
    // ⚠️ 性能红线（真机踩到）：
    //    早期版本用 setInterval(600ms) + querySelectorAll("*") 逐个读 textContent，
    //    并且穿透 shadow DOM —— textContent 会遍历整个子树，在本对话这种上万节点的页面上
    //    等于每 600ms 做上万次子树遍历，**把手机主线程打满**，
    //    导致 DSH 自己的异步请求（如 /api/workspaceFiles/stat）被饿死，
    //    文件查看器报"文件资源服务不可用"。桌面 CPU 扛得住所以没暴露。
    // ✅ 现在的做法：只在 **几个固定时刻** 跑（不常驻），且**只扫 button/[role=button]**
    //    （集合很小，innerText 也很轻）。跑完自动结束。
    this.js('(function(){if(window.__dshDis3){return;}window.__dshDis3=1;'
      + 'function ok(t){return t==="\u7ee7\u7eed"||t==="\u6211\u77e5\u9053\u4e86"||t==="\u5f00\u59cb\u4f7f\u7528";}'
      + 'function fire(el){try{el.click();}catch(e){}'
      + 'try{el.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window}));}catch(e){}}'
      + 'function tick(){try{'
      + 'var bs=document.querySelectorAll("button,[role=button]");'
      + 'for(var i=0;i<bs.length;i++){var el=bs[i];'
      + 'var t=(el.innerText||el.textContent||"").replace(/\\s/g,"");'
      + 'if(t.length===0||t.length>8)continue;'
      + 'if(!ok(t))continue;'
      + 'var r=el.getBoundingClientRect();'
      + 'if(r.width<=1||r.height<=1)continue;'
      + 'fire(el);return true;}}catch(e){}return false;}'
      + 'var dl=[400,1200,2500,5000,9000,15000];'
      + 'for(var k=0;k<dl.length;k++){(function(d){setTimeout(tick,d);})(dl[k]);}'
      + '})()');
    // ⑤ 已合并进 ⑦（下面）：弹窗检测统一由 __dshDialogOpen 负责，
    //    同时用于"侧滑关闭弹窗"和"隐藏左侧栏那行"，避免两个轮询互相覆盖状态。
    // ⑦ 浮层状态上报 + 关闭函数（右侧边栏 / 网页弹窗）
    //
    // ★ 这里有个坑（实测踩到）：
    //   收起右侧边栏后，[aria-label="收起右侧边栏"] 这个按钮**仍然留在 DOM 里**，
    //   只是被挪到屏幕外（x > innerWidth）。所以用 querySelector 判断"元素是否存在"
    //   会永远得到"展开中" —— 于是每次侧滑都去点那个屏外的按钮，
    //   而它的 handler 是 toggle，结果**把已经收起的右侧栏给打开了**。
    //   正确做法：判断按钮是否**落在视口内**。
    //   实测两态：
    //     展开 → [收起右侧边栏] 在视口内，[打开右侧边栏] 不在 DOM
    //     收起 → [打开右侧边栏] 在视口内，[收起右侧边栏] 在 DOM 但屏幕外
    //
    //   弹窗（设置等）：[role=dialog] / [aria-modal=true]，尺寸较大即为打开；
    //   关闭方式：点弹窗内的「关闭 / Close」按钮，退路是派发 Escape。
    this.js('(function(){if(window.__dshOv2){return;}window.__dshOv2=1;'
      + 'function iv(el){try{if(!el)return false;var r=el.getBoundingClientRect();'
      + 'return r.width>0&&r.height>0&&r.left<window.innerWidth&&r.right>0&&r.top<window.innerHeight&&r.bottom>0;}catch(e){return false;}}'
      // 颜色工具（原在 ① 里，合并到这里）
      + 'function rgbp(c){var m=c&&c.match(/rgba?\\(([\\d.]+),\\s*([\\d.]+),\\s*([\\d.]+)(?:,\\s*([\\d.]+))?\\)/);'
      + 'if(!m)return null;return{r:parseFloat(m[1]),g:parseFloat(m[2]),b:parseFloat(m[3]),a:m[4]===undefined?1:parseFloat(m[4])};}'
      + 'function hx(o){if(!o)return "";function h(x){var v=Math.round(x);if(v<0)v=0;if(v>255)v=255;var s=v.toString(16);return s.length<2?"0"+s:s;}'
      + 'return "#"+h(o.r)+h(o.g)+h(o.b);}'
      + 'function effBg(el){var n=el,d=0;while(n&&n!==document.documentElement&&d<12){d++;'
      + 'var c=getComputedStyle(n).backgroundColor;'
      + 'if(c&&c!=="rgba(0, 0, 0, 0)"&&c!=="transparent")return c;n=n.parentElement;}return "";}'
      + 'function blend(fg,bg){if(!fg)return "";if(!bg||fg.a>=1)return hx(fg);'
      + 'return hx({r:fg.a*fg.r+(1-fg.a)*bg.r,g:fg.a*fg.g+(1-fg.a)*bg.g,b:fg.a*fg.b+(1-fg.a)*bg.b});}'
      + 'window.__dshRightOpen=function(){try{'
      // 只有"折叠态"（窄屏）下右侧栏才是占满屏的浮层、才值得用返回键收起；
      // 展开态（内屏 >600）它是常驻分栏，返回键不应该把它收起来。
      + 'if(window.innerWidth>600)return false;'
      + 'if(iv(document.querySelector("[aria-label=\'打开右侧边栏\']")))return false;'
      + 'return iv(document.querySelector("[aria-label=\'收起右侧边栏\']"));}catch(e){return false;}};'
      // 弹窗检测：**只**看 [role=dialog]/[aria-modal=true]。
      // ⚠️ 早期版本还叠加了"遍历所有 div 调 getComputedStyle"的启发式 ——
      //    那会强制样式重算，在长页面上极耗；已删除（手机端会因此卡到接口超时）。
      + 'window.__dshDialogOpen=function(){try{var ds=document.querySelectorAll("[role=dialog],[aria-modal=true]");'
      + 'for(var i=0;i<ds.length;i++){var r=ds[i].getBoundingClientRect();if(r.width>120&&r.height>120)return true;}}catch(e){}return false;};'
      + 'window.__dshCloseRightPanel=function(){try{if(!window.__dshRightOpen())return;'
      + 'var b=document.querySelector("[aria-label=\'收起右侧边栏\']");if(b)b.click();}catch(e){}};'
      + 'window.__dshCloseDialog=function(){try{var ds=document.querySelectorAll("[role=dialog],[aria-modal=true]");'
      + 'for(var i=0;i<ds.length;i++){var d=ds[i];var r=d.getBoundingClientRect();if(!(r.width>120&&r.height>120))continue;'
      + 'var bs=d.querySelectorAll("button");for(var j=0;j<bs.length;j++){'
      + 'var t=(bs[j].getAttribute("aria-label")||bs[j].innerText||"");'
      + 'if(t.indexOf("关闭")>=0||t.indexOf("Close")>=0){bs[j].click();return;}}}'
      + 'document.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",code:"Escape",keyCode:27,which:27,bubbles:true}));}catch(e){}};'
      // ── 统一轮询（1000ms 一次）──────────────────────────────────
      // 只做三件事：
      //   ① 从侧栏底色亮度判断"是不是深色"，变化时才上报（原生据此给页面和状态栏条上色）
      //   ② 右侧栏是否全屏展开（返回键要先收它）——变化时才报
      //   ③ 是否有弹窗（返回键要先关它）——变化时才报
      // 不再上报配色细节和侧栏宽度：状态栏已改成一条纯色条，不需要对齐。
      + 'var railEl=null,lastDark=-1,lastOv=-1,lastDlg=-1;'
      + 'function tick(){try{'
      + 'if(!railEl||!document.contains(railEl)){railEl=document.querySelector("[class*=sidebarCol]");}'
      + 'if(railEl){var bg=rgbp(effBg(railEl));'
      + 'if(bg){var lum=(0.299*bg.r+0.587*bg.g+0.114*bg.b)/255;var dk=lum<0.5?1:0;'
      + 'if(dk!==lastDark){lastDark=dk;window.dshShell.setDark(dk);}}}'
      + 'var ov=window.__dshRightOpen()?1:0;if(ov!==lastOv){lastOv=ov;window.dshShell.setOverlay(ov);}'
      + 'var dg=window.__dshDialogOpen()?1:0;if(dg!==lastDlg){lastDlg=dg;window.dshShell.setDialog(dg);}'
      + '}catch(e){}}'
      // ★ 只靠轮询有竞态：用户"刚打开右侧栏就立刻侧滑返回"时，
      //   原生还没收到 setOverlay(1)，onBackPress 就已经跑了 ——
      //   表现就是**侧滑关闭右侧栏时灵时不灵**（用户实测反馈）。
      //   补一路"点击后立刻重算"：打开右侧栏/弹窗都是点击触发的，点完 80ms 就上报。
      + 'document.addEventListener("click",function(){setTimeout(tick,80);},true);'
      + 'setTimeout(tick,300);setInterval(tick,600);'
      + '})()');
    // ⑥ 「当前连接情况」行：插进网页左侧栏，点它弹出站点切换面板。
    //    文字**不再轮询拉取**（用户要求：不切站点就没必要反复问原生）；
    //    改为：这里只负责"确保元素存在 + 首次填字"，之后由原生在切换站点时主动推送
    //    （见 pushCurLabel()）。
    this.js('(function(){if(window.__dshCur){return;}window.__dshCur=1;'
      + 'function ensure(){try{'
      + 'if(!document.getElementById("dsh-curlbl")){'
      + 'var row=document.querySelector("[class*=logoRow]");'
      + 'if(!row||!row.parentElement)return false;'
      + 'var d=document.createElement("div");d.id="dsh-curlbl";'
      + 'd.style.cssText="font-size:11px;color:#8a8a8a;padding:2px 14px 8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer;";'
      + 'd.onclick=function(){try{window.dshShell.openSwitcher();}catch(e){}};'
      + 'row.parentElement.insertBefore(d,row.nextSibling);'
      + 'd.textContent=window.dshShell.getCurLabel()||"";'
      + 'return true;}'
      + 'return false;}catch(e){return false;}}'
      + 'var n=0;var t=setInterval(function(){n++;if(ensure()||n>40){clearInterval(t);}},700);'
      + '})()');
  }

  buildBridge(): ShellBridge {
    const bridge: ShellBridge = {
      getGroups: (): string => {
        return JSON.stringify(this.groups);
      },
      getCurrent: (): string => {
        return '{"g":' + this.curG.toString() + ',"i":' + this.curI.toString() + '}';
      },
      saveGroups: (json: string): void => {
        try {
          const arr = JSON.parse(json) as Group[];
          if (arr.length > 0) {
            this.groups = arr;
            this.saveStore();
          }
        } catch (e) {
        }
      },
      switchTo: (g: number, i: number): void => {
        this.connect(g, i);
      },
      getSafeTop: (): number => {
        return this.safeTop;
      },
      getSafeBottom: (): number => {
        return this.safeBottom;
      },
      log: (m: string): void => {
        this.addLog(m);
      },
      // 下载并用系统应用打开（office/pdf）。json = {url, name, mime}
      openFile: (json: string): void => {
        this.openWithSystem(json);
      },
      openSites: (): void => {
        this.backToPicker();
      },
      dbg: (m: string): void => {
        this.webConsoleErr = m;
      },
      setOverlay: (v: number): void => {
        this.webOverlay = (v === 1);
      },
      // 自建文件查看器上报开合状态（返回键/侧滑据此先关它）
      setFileFix: (v: number): void => {
        this.fileFixOpen = (v === 1);
      },
      // 网页只上报"当前是不是深色"（由侧栏底色亮度算出）。
      // 不再上报具体配色，也不再上报侧栏宽度 —— 状态栏已改成一条纯色条。
      setDark: (v: number): void => {
        const dark = (v === 1);
        if (dark === this.isDark) {
          return;
        }
        this.isDark = dark;
        this.applySysBarIcons(dark);
        try {
          if (this.store !== null) {
            this.store.putSync(KEY_DARK, dark ? '1' : '0');
            this.store.flush();
          }
        } catch (e) {
        }
      },
      setDialog: (v: number): void => {
        const on = (v === 1);
        if (on !== this.dialogOpen) {
          this.dialogOpen = on;
        }
      },
      getCurLabel: (): string => {
        return this.curLabel();
      },
      openSwitcher: (): void => {
        this.showSwitcher = true;
      }
    };
    return bridge;
  }

  onBackPress(): boolean {
    // 排序模式下返回：先放弃本次排序改动（用户要求"默认不保存"），停在站点页
    if (this.sortMode) {
      this.groups = this.sortBackup;
      this.sortMode = false;
      this.saveStore();
      this.refreshCurLabel();
      return true;
    }
    if (this.panelMode === 'edit') {
      this.panelMode = 'list';
      return true;
    }
    if (this.panelMode === 'backup') {
      this.saveDavCfg();
      this.panelMode = 'list';
      return true;
    }
    if (this.phase === PHASE_WEB) {
      // 返回的三级行为（按用户要求）：
      //   ① 网页里开着弹窗（DSH 设置等）→ 先关弹窗
      //   ② 右侧边栏展开**且处于折叠态（窄屏占满屏）** → 先收起它
      //      （展开态/内屏下右侧栏是常驻分栏，返回键不收起它）
      //   ③ 都没有 → 两段式退出 App（第一次提示"再按一次退出"）
      // 这两个状态由注入脚本按「元素是否在视口内 + innerWidth」上报
      // （只看元素是否存在会永远为真，见 ⑦ 的注释）。
      // ⓪ 自建文件查看器开着 → 最先关它
      //    用户要求：侧滑/返回键能关掉查看器。开合状态由查看器脚本经 setFileFix 上报。
      if (this.fileFixOpen) {
        try {
          this.controller.runJavaScript('window.__dshCloseFileFix && window.__dshCloseFileFix()');
        } catch (e) {
        }
        this.fileFixOpen = false;
        return true;
      }
      if (this.dialogOpen) {
        try {
          this.controller.runJavaScript('window.__dshCloseDialog && window.__dshCloseDialog()');
        } catch (e) {
        }
        this.dialogOpen = false;
        return true;
      }
      if (this.webOverlay) {
        try {
          this.controller.runJavaScript('window.__dshCloseRightPanel && window.__dshCloseRightPanel()');
        } catch (e) {
        }
        this.webOverlay = false;
        return true;
      }
      // ③ 主页面：两段式退出（第一次提示"再按一次退出"，2 秒内再按才真正退出）
      //    注意：右侧栏只在"折叠态（窄屏）"才算需要收起的浮层，
      //    展开态它是常驻分栏，返回键不碰它（由注入脚本按 innerWidth 判定）。
      const t2 = Date.now();
      if (t2 - this.lastBackTime < 2000) {
        return false;
      }
      this.lastBackTime = t2;
      promptAction.showToast({ message: '再按一次退出', duration: 2000 });
      return true;
    }
    if (this.phase === PHASE_LOADING || this.phase === -1) {
      this.backToPicker();
      return true;
    }
    // 在站点页：如果之前已经进过网页，返回应该回到网页（而不是退出 App）
    if (this.phase === PHASE_PICKER && this.visited) {
      this.backToWeb();
      return true;
    }
    const now = Date.now();
    if (now - this.lastBackTime < 2000) {
      return false;
    }
    this.lastBackTime = now;
    promptAction.showToast({ message: '再按一次退出', duration: 2000 });
    return true;
  }

  dotColor(a: Address): string {
    if (a.off) {
      // 停用：浅灰 / 深色下压暗
      return this.tc('#CCCCCC', '#55555D');
    }
    if (a.link === 'ok') {
      return '#22BB55';
    }
    if (a.link === 'fail') {
      return '#EE9933';
    }
    // 未测：深色下这个点要比卡片底亮，否则看不见
    return this.tc('#DDDDDD', '#5A5A62');
  }

  linkText(a: Address): string {
    let s: string = '';
    const errText: string = a.err ? a.err : '';
    if (a.off) {
      s = '已停用';
    } else if (a.link === 'ok') {
      s = '能打开';
    } else if (a.link === 'fail') {
      s = '可能打不开';
    } else {
      s = '还没测';
    }
    if (errText.length > 0) {
      s = s + ' · ' + errText;
    }
    return s;
  }

  // ── 站点快速切换面板 ───────────────────────────────────────────
  @Builder
  SwitcherSheet() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text('切换站点')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
          Text('点一条即切换，灰色停用的不会出现')
            .fontSize(11)
            .fontColor(this.tc('#999999', '#8A8A92'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('关闭')
          .fontSize(13)
          .height(32)
          .backgroundColor(this.tc('#EFEFEF', '#2E2E34'))
          .fontColor('#0A59F7')
          .onClick(() => {
            this.showSwitcher = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll() {
        Column() {
          ForEach(this.groups, (g: Group, gi: number) => {
            Text(g.name)
              .fontSize(12)
              .fontColor(this.tc('#999999', '#8A8A92'))
              .width('100%')
              .padding({ left: 16, top: 12, bottom: 4 })
            ForEach(g.items, (a: Address, ai: number) => {
              if (!a.off) {
                Row({ space: 10 }) {
                  Circle({ width: 8, height: 8 })
                    .fill(this.dotColor(a))
                  Column({ space: 2 }) {
                    Text(a.name && a.name.length > 0 ? a.name : a.url)
                      .fontSize(14)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(a.url)
                      .fontSize(11)
                      .fontColor(this.tc('#999999', '#8A8A92'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (gi === this.curG && ai === this.curI) {
                    Text('当前')
                      .fontSize(11)
                      .fontColor('#0A59F7')
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .backgroundColor(gi === this.curG && ai === this.curI ? this.tc('#EEF4FF', '#182740') : this.tc('#FFFFFF', '#1C1C20'))
                .onClick(() => {
                  this.showSwitcher = false;
                  if (gi !== this.curG || ai !== this.curI) {
                    this.connect(gi, ai);
                  }
                })
              }
            }, (a: Address, ai: number) => 's' + gi.toString() + '-' + ai.toString())
          }, (g: Group, gi: number) => (g.name ? g.name : '') + '#' + gi.toString() + '#' + (g.ver ? g.ver.toString() : '0') + 'L')
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('72%')
    .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
    .borderRadius({ topLeft: 18, topRight: 18 })
  }

  // ── 选站点页 ───────────────────────────────────────────────────
  // 站点页直接排序：站点页没有"保存"按钮，所以立即改 groups 并持久化
  moveGroupDirect(gi: number, d: number): void {
    const w = JSON.parse(JSON.stringify(this.groups)) as Group[];
    const t = gi + d;
    if (t < 0 || t >= w.length) {
      return;
    }
    const tmp = w[gi];
    w[gi] = w[t];
    w[t] = tmp;
    // 关键：排序改变了数组索引，而"当前站点"是用索引记的（curG/curI），
    // 必须同步，否则排序后「当前连接」会指向另一个系统。
    if (this.curG === gi) {
      this.curG = t;
    } else if (this.curG === t) {
      this.curG = gi;
    }
    this.groups = [];
    this.groups = w;
    this.saveStore();
    this.refreshCurLabel();
  }

  moveAddrDirect(gi: number, ai: number, d: number): void {
    const w = JSON.parse(JSON.stringify(this.groups)) as Group[];
    if (gi < 0 || gi >= w.length) {
      return;
    }
    const items = w[gi].items;
    const t = ai + d;
    if (t < 0 || t >= items.length) {
      return;
    }
    const tmp = items[ai];
    items[ai] = items[t];
    items[t] = tmp;
    // 同理：同一系统内交换地址后要同步 curI
    if (this.curG === gi) {
      if (this.curI === ai) {
        this.curI = t;
      } else if (this.curI === t) {
        this.curI = ai;
      }
    }
    // 关键：地址换序不改变外层系统的 name/索引，若不 bump 版本号，
    // 外层 ForEach 的 key 不变 → ArkUI 不重建内层列表 → 界面看起来"点了没反应"。
    const curVer = w[gi].ver;
    w[gi].ver = (curVer ? curVer : 0) + 1;
    this.groups = [];
    this.groups = w;
    this.saveStore();
  }

  // 站点页拖拽排序：把第 from 个系统移动到 to 位置（位置由 List 拖拽给出）
  moveGroupToDirect(from: number, to: number): void {
    const w = JSON.parse(JSON.stringify(this.groups)) as Group[];
    if (from < 0 || from >= w.length || to < 0 || to >= w.length || from === to) {
      return;
    }
    const item = w.splice(from, 1)[0];
    w.splice(to, 0, item);
    this.groups = [];
    this.groups = w;
    this.saveStore();
    this.refreshCurLabel();
  }

  groupHint(g: Group): string {
    let n = 0;
    for (let i = 0; i < g.items.length; i++) {
      if (!g.items[i].off) {
        n = n + 1;
      }
    }
    return n.toString() + ' / ' + g.items.length.toString() + ' 条可用';
  }

  // 折叠屏断点适配：算"内容区最大宽度"与"是否宽屏"。
  // 参照 Material Design 3 的 Window Size Classes：
  //   Compact  < 600vp  单列、内容铺满
  //   Medium   600-840  内容限宽居中（约 680）
  //   Expanded > 840    内容限宽居中（约 760）
  // 目的：内屏展开时不让每行文字被拉得过长，同时保持视觉居中。
  contentW(): number {
    const w = this.winW > 0 ? this.winW : 420;
    if (w >= 840) {
      return 760;
    }
    if (w >= 600) {
      return 680;
    }
    return w;
  }

  isWide(): boolean {
    return this.winW >= 600;
  }

  // 切换面板宽度：窄屏铺满底部，宽屏居中做浮层卡片
  sheetW(): number {
    const w = this.contentW();
    return w >= 600 ? 560 : w;
  }

  @Builder
  PickerPage() {
    Column() {
      // 顶部标题栏
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('站点')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
          Text(this.verText)
            .fontSize(10)
            .fontColor(this.tc('#BBBBBB', '#6E6E76'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.sortMode ? '完成' : '排序')
          .fontSize(13)
          .height(32)
          .backgroundColor(this.sortMode ? '#0A59F7' : this.tc('#FFFFFF', '#1C1C20'))
          .fontColor(this.sortMode ? '#FFFFFF' : '#0A59F7')
          .border({ width: 1, color: this.sortMode ? '#0A59F7' : this.tc('#E2E2E2', '#33333A') })
          .onClick(() => {
            if (this.sortMode) {
              // 点「完成」：保留本次排序
              this.sortMode = false;
            } else {
              // 进入排序模式前先做快照，方便「返回」时放弃
              this.sortBackup = JSON.parse(JSON.stringify(this.groups)) as Group[];
              this.sortMode = true;
            }
          })
        Button('编辑')
          .fontSize(13)
          .height(32)
          .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
          .fontColor('#0A59F7')
          .border({ width: 1, color: this.tc('#E2E2E2', '#33333A') })
          .onClick(() => {
            this.openEdit();
          })
        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor('#0A59F7')
          .fontColor('#FFFFFF')
          .onClick(() => {
            // 排序模式下点「返回」：只退出排序状态并放弃改动，留在站点页（不跳回网页）
            if (this.sortMode) {
              this.groups = this.sortBackup;
              this.sortMode = false;
              this.saveStore();
              this.refreshCurLabel();
              return;
            }
            this.backToWeb();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })

      // 当前连接（胶囊卡片）
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Text('当前连接')
            .fontSize(11)
            .fontColor('#0A59F7')
          if (this.probing) {
            Text('检测中…')
              .fontSize(11)
              .fontColor(this.tc('#999999', '#8A8A92'))
          }
        }
        .width('100%')

        Text(this.curLabelText)
          .fontSize(13)
          .fontColor(this.tc('#1F1F1F', '#E6E6E9'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .padding(14)
      .constraintSize({ maxWidth: this.contentW() })
      .margin({ left: 16, right: 16, bottom: 10 })
      .borderRadius(14)
      .backgroundColor(this.tc('#EAF1FF', '#182740'))

      // 说明 + 重新检测
      Row({ space: 10 }) {
        Text('绿=可打开 · 橙=没打开 · 灰=没测过 · 🔑=已配账号')
          .fontSize(11)
          .fontColor(this.tc('#A0A0A0', '#8A8A92'))
          .layoutWeight(1)
        Button(this.probing ? '检测中…' : '重新检测')
          .fontSize(12)
          .height(30)
          .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
          .fontColor('#0A59F7')
          .border({ width: 1, color: this.tc('#E2E2E2', '#33333A') })
          .enabled(!this.probing)
          .onClick(() => {
            this.startProbeAll();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.contentW() })
      .padding({ left: 16, right: 16, bottom: 10 })

      List({ space: 16 }) {
        ForEach(this.groups, (g: Group, gi: number) => {
          ListItem() {
            Column() {
              // 系统卡片头
              Row({ space: 8 }) {
                Text((g.name && g.name.length > 0) ? g.name : ('系统 ' + (gi + 1).toString()))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.tc('#2B2B2B', '#E6E6E9'))
                  .layoutWeight(1)
                Text(this.groupHint(g))
                  .fontSize(11)
                  .fontColor(this.tc('#B0B0B0', '#7E7E86'))
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 8 })

              // 排序按钮独占一行，且只在"排序模式"下显示（平时保持列表清爽）
              if (this.sortMode) {
                Row({ space: 8 }) {
                  Button('系统上移')
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(gi > 0 ? this.tc('#EAEAEA', '#2E2E34') : this.tc('#F5F5F5', '#232328'))
                    .fontColor(gi > 0 ? this.tc('#222222', '#E6E6E9') : this.tc('#D0D0D0', '#5A5A62'))
                    .enabled(gi > 0)
                    .onClick(() => {
                      this.moveGroupDirect(gi, -1);
                    })
                  Button('系统下移')
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(gi < this.groups.length - 1 ? this.tc('#EAEAEA', '#2E2E34') : this.tc('#F5F5F5', '#232328'))
                    .fontColor(gi < this.groups.length - 1 ? this.tc('#222222', '#E6E6E9') : this.tc('#D0D0D0', '#5A5A62'))
                    .enabled(gi < this.groups.length - 1)
                    .onClick(() => {
                      this.moveGroupDirect(gi, 1);
                    })
                }
                .width('100%')
                .padding({ left: 14, right: 14, bottom: 10 })
              }

              Divider()
                .color(this.tc('#F2F2F2', '#2A2A30'))
                .strokeWidth(1)
                .margin({ left: 14, right: 14 })

              ForEach(g.items, (a: Address, ai: number) => {
                Column() {
                Row({ space: 12 }) {
                  Circle({ width: 8, height: 8 })
                    .fill(this.dotColor(a))
                  Column({ space: 3 }) {
                    Row({ space: 6 }) {
                      Text((a.name && a.name.length > 0) ? a.name : a.url)
                        .fontSize(15)
                        .fontColor(a.off ? this.tc('#BBBBBB', '#6E6E76') : this.tc('#1F1F1F', '#E6E6E9'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      if (a.user && a.user.length > 0) {
                        Text('🔑')
                          .fontSize(12)
                      }
                    }
                    .width('100%')

                    Text(a.url)
                      .fontSize(11)
                      .fontColor(a.off ? this.tc('#CCCCCC', '#6E6E76') : this.tc('#9A9A9A', '#8A8A92'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')

                    Text(a.off ? '已停用' : this.linkText(a))
                      .fontSize(11)
                      .fontColor(a.off ? this.tc('#BBBBBB', '#6E6E76') : (a.link === 'fail' ? this.tc('#EE9933', '#F0A64D') : (a.link === 'ok' ? this.tc('#22BB55', '#43D17A') : this.tc('#AAAAAA', '#7E7E86'))))
                      .width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .backgroundColor(a.off ? this.tc('#FAFAFA', '#17171A') : this.tc('#FFFFFF', '#1C1C20'))
                .onClick(() => {
                  if (!this.sortMode && !a.off) {
                    this.connect(gi, ai);
                  }
                })

                // 地址排序：只在排序模式下出现，独占一行避免被挤压
                if (this.sortMode) {
                  Row({ space: 8 }) {
                    Button('地址上移')
                      .fontSize(13)
                      .height(36)
                      .layoutWeight(1)
                      .backgroundColor(ai > 0 ? this.tc('#EAEAEA', '#2E2E34') : this.tc('#F5F5F5', '#232328'))
                      .fontColor(ai > 0 ? this.tc('#222222', '#E6E6E9') : this.tc('#D0D0D0', '#5A5A62'))
                      .enabled(ai > 0)
                      .onClick(() => {
                        this.moveAddrDirect(gi, ai, -1);
                      })
                    Button('地址下移')
                      .fontSize(13)
                      .height(36)
                      .layoutWeight(1)
                      .backgroundColor(ai < g.items.length - 1 ? this.tc('#EAEAEA', '#2E2E34') : this.tc('#F5F5F5', '#232328'))
                      .fontColor(ai < g.items.length - 1 ? this.tc('#222222', '#E6E6E9') : this.tc('#D0D0D0', '#5A5A62'))
                      .enabled(ai < g.items.length - 1)
                      .onClick(() => {
                        this.moveAddrDirect(gi, ai, 1);
                      })
                  }
                  .width('100%')
                  .padding({ left: 14, right: 14, bottom: 10 })
                }
                }
                .width('100%')
                .backgroundColor(a.off ? this.tc('#FAFAFA', '#17171A') : this.tc('#FFFFFF', '#1C1C20'))
              }, (a: Address, ai: number) => (a.url ? a.url : '') + '#' + gi.toString() + '-' + ai.toString() + (a.off ? 'F' : 'T') + (a.link ? a.link : '') + 'L')
            }
            .width('100%')
            .margin({ bottom: 12 })
            .borderRadius(14)
            .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
            .border({ width: 1, color: this.tc('#D3DAE4', '#2E2E34') })
            .clip(true)
            }
          }, (g: Group, gi: number) => (g.name ? g.name : '') + '#' + gi.toString() + '#' + (g.ver ? g.ver.toString() : '0') + 'L')
      }
      .layoutWeight(1)
      .width('100%')

      // 空站点引导（清空配置后第一次打开时不至于一片空白）
      if (this.groups.length === 0) {
        Column({ space: 8 }) {
          Text('还没有配置站点')
            .fontSize(15)
            .fontColor(this.tc('#8A94A6', '#9C9CA4'))
          Text('点右上角「编辑」→ 底部「＋ 新增一个系统」开始添加\n也可以用下面的 WebDAV 备份恢复')
            .fontSize(12)
            .fontColor(this.tc('#AAB4C4', '#7E7E86'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 36, bottom: 6 })
        .constraintSize({ maxWidth: this.contentW() })
      }

      Text('共 ' + this.groups.length.toString() + ' 个系统 · 点右上角「排序」可调整顺序')
        .fontSize(11)
        .fontColor(this.tc('#C8C8C8', '#66666E'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 8 })
        .constraintSize({ maxWidth: this.contentW() })

      // WebDAV 备份入口
      Row({ space: 6 }) {
        Text('☁')
          .fontSize(14)
          .fontColor('#0A59F7')
        Text('WebDAV 站点备份 / 恢复')
          .fontSize(12)
          .fontColor('#0A59F7')
        if (this.davLast.length > 0) {
          Text('· 上次 ' + this.davLast)
            .fontSize(10)
            .fontColor(this.tc('#AAB4C4', '#7E7E86'))
        }
      }
      .padding({ top: 6, bottom: 20 })
      .constraintSize({ maxWidth: this.contentW() })
      .onClick(() => {
        this.panelMode = 'backup';
      })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, bottom: this.safeBottom })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.tc('#DDE3EB', '#111114'))
  }

  // ── 编辑页 ─────────────────────────────────────────────────────
  @Builder
  miniBtn(label: string, enabled: boolean, act: () => void) {
    Button(label)
      .fontSize(15)
      .height(38)
      .width(48)
      .backgroundColor(enabled ? this.tc('#E8E8E8', '#2E2E34') : this.tc('#F6F6F6', '#232328'))
      .fontColor(enabled ? this.tc('#222222', '#E6E6E9') : this.tc('#D8D8D8', '#5A5A62'))
      .enabled(enabled)
      .onClick(act)
  }

  @Builder
  EditPage() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('编辑站点')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
          Text('在这里编辑系统与地址；顺序请到站点页点「排序」调整')
            .fontSize(10)
            .fontColor(this.tc('#BBBBBB', '#6E6E76'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
          .fontColor(this.tc('#333333', '#DDDDE1'))
          .border({ width: 1, color: this.tc('#E2E2E2', '#33333A') })
          .onClick(() => {
            this.dbgText = '返回被点到';
            this.panelMode = 'list';
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })

      List({ space: 16 }) {
        ForEach(this.working, (g: Group, gi: number) => {
          ListItem() {
            Column() {
              // 系统名
              Row({ space: 8 }) {
                TextInput({ text: g.name, placeholder: '系统名，例如 winnas' })
                  .height(42)
                  .fontSize(14)
                  .layoutWeight(1)
                  .backgroundColor(this.tc('#F2F3F5', '#26262B'))
                  .onChange((v: string) => {
                    this.working[gi].name = v;
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 8 })

              Divider()
                .color(this.tc('#F2F2F2', '#2A2A30'))
                .strokeWidth(1)
                .margin({ left: 12, right: 12 })

              ForEach(g.items, (a: Address, ai: number) => {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    Text('地址 ' + (ai + 1).toString())
                      .fontSize(12)
                      .fontColor(this.tc('#9A9A9A', '#8A8A92'))
                      .layoutWeight(1)
                  }
                  .width('100%')

                  TextInput({ text: a.name, placeholder: '备注名（可空）' })
                    .height(40)
                    .fontSize(14)
                    .width('100%')
                    .backgroundColor(this.tc('#F7F7F7', '#26262B'))
                    .onChange((v: string) => {
                      this.working[gi].items[ai].name = v;
                    })
                  TextInput({ text: a.url, placeholder: '网址，例如 https://host:8443' })
                    .height(40)
                    .fontSize(14)
                    .width('100%')
                    .backgroundColor(this.tc('#F7F7F7', '#26262B'))
                    .onChange((v: string) => {
                      this.working[gi].items[ai].url = v;
                    })
                  Row({ space: 8 }) {
                    TextInput({ text: a.user, placeholder: '账号（可空）' })
                      .height(40)
                      .fontSize(14)
                      .layoutWeight(1)
                      .backgroundColor(this.tc('#F7F7F7', '#26262B'))
                      .onChange((v: string) => {
                        this.working[gi].items[ai].user = v;
                      })
                    TextInput({ text: a.pass, placeholder: '密码（自动登录）' })
                      .height(40)
                      .fontSize(14)
                      .layoutWeight(1)
                      .backgroundColor(this.tc('#F7F7F7', '#26262B'))
                      .onChange((v: string) => {
                        this.working[gi].items[ai].pass = v;
                      })
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Button(a.off ? '已停用 · 点启用' : '启用中 · 点停用')
                      .fontSize(12)
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(a.off ? '#0A59F7' : this.tc('#F2F2F2', '#2A2A30'))
                      .fontColor(a.off ? '#FFFFFF' : this.tc('#666666', '#A6A6AE'))
                      .onClick(() => {
                        this.toggleOff(gi, ai);
                      })
                    Button('删除')
                      .fontSize(12)
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(this.tc('#FDECEC', '#3A1E1E'))
                      .fontColor(this.tc('#CC3333', '#FF8A8A'))
                      .onClick(() => {
                        this.removeAddress(gi, ai);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(12)
                .margin({ left: 12, right: 12, bottom: 10 })
                .borderRadius(10)
                .backgroundColor(a.off ? this.tc('#FAFAFA', '#17171A') : this.tc('#FFFFFF', '#1C1C20'))
                .border({ width: 1, color: this.tc('#DDE3EC', '#2E2E34') })
              }, (a: Address, ai: number) => (a.url ? a.url : '') + '#' + gi.toString() + '-' + ai.toString() + (a.off ? 'F' : 'T') + (a.link ? a.link : ''))


              Row({ space: 8 }) {
                Button('＋ 加一条地址')
                  .fontSize(13)
                  .height(38)
                  .layoutWeight(1)
                  .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
                  .fontColor('#0A59F7')
                  .border({ width: 1, color: this.tc('#C8D8F8', '#2A3E63'), style: BorderStyle.Dashed })
                  .onClick(() => {
                    this.addAddress(gi);
                  })
                Button('删除这个系统')
                  .fontSize(13)
                  .height(38)
                  .width(120)
                  .backgroundColor(this.tc('#FDECEC', '#3A1E1E'))
                  .fontColor(this.tc('#CC3333', '#FF8A8A'))
                  .border({ width: 1, color: this.tc('#F5C6C6', '#5A2A2A') })
                  .onClick(() => {
                    this.removeSystem(gi);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, bottom: 12 })
            }
            .width('100%')
            .margin({ bottom: 16 })
            .borderRadius(14)
            .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
            .border({ width: 1, color: this.tc('#E6E8EB', '#2E2E34') })
            .shadow({ radius: 14, color: this.tc('#26000000', '#00000000'), offsetX: 0, offsetY: 3 })
            .clip(true)
            }
          }, (g: Group, gi: number) => (g.name ? g.name : '') + '#' + gi.toString() + '#' + (g.ver ? g.ver.toString() : '0'))

      }
      .layoutWeight(1)
      .width('100%')
      .constraintSize({ maxWidth: this.contentW() })
      .padding({ left: 16, right: 16 })
      // 长按卡片拖拽排序（ArkUI 官方 List 拖拽）
      .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
        this.dragIdx = itemIndex;
        return this.dragCardView(itemIndex);
      })

      .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
        if (isSuccess) {
          this.moveGroupTo(itemIndex, insertIndex);
        }
      })

      Button('＋ 新增一个系统')
        .fontSize(14)
        .height(42)
        .width('100%')
        .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
        .fontColor('#0A59F7')
        .border({ width: 1, color: '#0A59F7', style: BorderStyle.Dashed })
        .margin({ left: 16, right: 16, bottom: 14 })
        .constraintSize({ maxWidth: this.contentW() })
        .onClick(() => {
          this.addSystem();
        })

      Row({ space: 10 }) {
        Button('取消')
          .fontSize(15)
          .height(46)
          .layoutWeight(1)
          .backgroundColor(this.tc('#F0F0F0', '#2E2E34'))
          .fontColor(this.tc('#444444', '#CFCFD4'))
          .onClick(() => {
            this.panelMode = 'list';
          })
        Button('保存')
          .fontSize(15)
          .height(46)
          .layoutWeight(1)
          .onClick(() => {
            this.saveWorking();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, bottom: this.safeBottom })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.tc('#DDE3EB', '#111114'))
  }

  // ── 连接中页 ───────────────────────────────────────────────────
  @Builder
  LoadingPage() {
    Column() {
      Blank().layoutWeight(3)
      Image($r('app.media.startIcon')).width(96).height(96)
      LoadingProgress().width(42).height(42).color('#0A59F7').margin({ top: 20 })
      Text(this.hint).fontSize(14).fontColor(this.tc('#888888', '#9C9CA4')).margin({ top: 14 })
      Text(this.verText).fontSize(10).fontColor(this.tc('#CCCCCC', '#6E6E76')).margin({ top: 6 })
      Blank().layoutWeight(2)
      Button('站点')
        .fontSize(15)
        .height(44)
        .width(180)
        .backgroundColor(this.tc('#EFEFEF', '#2E2E34'))
        .fontColor('#0A59F7')
        .onClick(() => {
          this.backToPicker();
        })
      Blank().layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, bottom: this.safeBottom })
    .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
  }

  // ── 站点备份页（WebDAV） ────────────────────────────────────────
  @Builder
  BackupPage() {
    Column() {
      // 顶部标题栏
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('站点备份')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
          Text('WebDAV · ' + DAV_DIR)
            .fontSize(10)
            .fontColor(this.tc('#BBBBBB', '#6E6E76'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor('#0A59F7')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.saveDavCfg();
            this.panelMode = 'list';
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.contentW() })
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          // 配置卡片
          Column({ space: 10 }) {
            Text('WebDAV 服务器')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.tc('#2B2B2B', '#E6E6E9'))
              .width('100%')

            TextInput({ text: this.davUrl, placeholder: 'http://192.168.1.10:8080' })
              .height(42)
              .fontSize(14)
              .width('100%')
              .backgroundColor(this.tc('#F2F3F5', '#26262B'))
              .onChange((v: string) => {
                this.davUrl = v;
              })

            TextInput({ text: this.davUser, placeholder: '用户名（可空 = 匿名）' })
              .height(42)
              .fontSize(14)
              .width('100%')
              .backgroundColor(this.tc('#F2F3F5', '#26262B'))
              .onChange((v: string) => {
                this.davUser = v;
              })

            TextInput({ text: this.davPass, placeholder: '密码（可空）' })
              .type(InputType.Password)
              .height(42)
              .fontSize(14)
              .width('100%')
              .backgroundColor(this.tc('#F2F3F5', '#26262B'))
              .onChange((v: string) => {
                this.davPass = v;
              })

            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text('自动备份')
                  .fontSize(14)
                  .fontColor(this.tc('#1F1F1F', '#E6E6E9'))
                Text('站点有改动时自动上传（延迟 8 秒）')
                  .fontSize(10)
                  .fontColor(this.tc('#AAAAAA', '#7E7E86'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.davAuto })
                .selectedColor('#0A59F7')
                .onChange((on: boolean) => {
                  this.davAuto = on;
                  this.saveDavCfg();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .borderRadius(14)
          .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
          .border({ width: 1, color: this.tc('#D3DAE4', '#2E2E34') })
          .shadow({ radius: 14, color: this.tc('#26000000', '#00000000'), offsetX: 0, offsetY: 3 })

          // 操作卡片
          Column({ space: 10 }) {
            // 第 1 行：测试连接
            Button(this.davTesting ? '测试中…' : '测试连接')
              .fontSize(14)
              .height(42)
              .width('100%')
              .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
              .fontColor('#0A59F7')
              .border({ width: 1, color: '#0A59F7' })
              .enabled(!this.davBusy && !this.davTesting)
              .onClick(() => {
                this.saveDavCfg();
                this.davTest();
              })

            // 第 2 行：备份 / 恢复
            Row({ space: 10 }) {
              Button(this.davBusy ? '处理中…' : '立即备份')
                .fontSize(14)
                .height(44)
                .layoutWeight(1)
                .backgroundColor('#0A59F7')
                .fontColor('#FFFFFF')
                .enabled(!this.davBusy && !this.davTesting)
                .onClick(() => {
                  this.saveDavCfg();
                  this.davBackup(true);
                })
              Button('从备份恢复')
                .fontSize(14)
                .height(44)
                .layoutWeight(1)
                .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
                .fontColor('#0A59F7')
                .border({ width: 1, color: '#0A59F7' })
                .enabled(!this.davBusy && !this.davTesting)
                .onClick(() => {
                  this.saveDavCfg();
                  this.davRestore();
                })
            }
            .width('100%')

            // 传输进度（有传输时才出现）
            if (this.davPhase.length > 0) {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(this.davPhase + '…')
                    .fontSize(12)
                    .fontColor('#0A59F7')
                    .layoutWeight(1)
                  Text(this.davProgress.toString() + '%')
                    .fontSize(12)
                    .fontColor('#0A59F7')
                }
                .width('100%')

                Progress({ value: this.davProgress, total: 100, type: ProgressType.Linear })
                  .width('100%')
                  .height(6)
                  .color('#0A59F7')

                if (this.davProgressText.length > 0) {
                  Text(this.davProgressText)
                    .fontSize(11)
                    .fontColor(this.tc('#8A94A6', '#9C9CA4'))
                    .width('100%')
                }
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor(this.tc('#F0F5FF', '#182740'))
            }

            Text(this.davMsg.length > 0 ? this.davMsg : '备份目录会在首次备份时自动创建')
              .fontSize(12)
              .fontColor(this.davMsg.indexOf('失败') >= 0 ? this.tc('#CC3333', '#FF8A8A') : this.tc('#666666', '#A6A6AE'))
              .width('100%')

            if (this.davLast.length > 0) {
              Text('上次成功备份：' + this.davLast)
                .fontSize(11)
                .fontColor(this.tc('#999999', '#8A8A92'))
                .width('100%')
            }
          }
          .width('100%')
          .padding(14)
          .borderRadius(14)
          .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
          .border({ width: 1, color: this.tc('#D3DAE4', '#2E2E34') })
          .shadow({ radius: 14, color: this.tc('#26000000', '#00000000'), offsetX: 0, offsetY: 3 })

          // 自检日志（测试连接后出现）
          if (this.davTestLog.length > 0) {
            Column({ space: 6 }) {
              Row({ space: 6 }) {
                Text(this.davTesting ? '正在自检…' : (this.davTestOk ? '自检结果：通过' : '自检结果：未通过'))
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.davTesting ? '#0A59F7' : (this.davTestOk ? this.tc('#22BB55', '#43D17A') : this.tc('#CC3333', '#FF8A8A')))
                  .layoutWeight(1)
                if (!this.davTesting && this.davTestLog.length > 0) {
                  Text('清除')
                    .fontSize(12)
                    .fontColor(this.tc('#8A94A6', '#9C9CA4'))
                    .onClick(() => {
                      this.davTestLog = '';
                      this.davTestOk = false;
                    })
                }
              }
              .width('100%')

              Text(this.davTestLog)
                .fontSize(11)
                .fontColor(this.tc('#4A5568', '#B4B4BC'))
                .width('100%')
                .lineHeight(18)
            }
            .width('100%')
            .padding(12)
            .borderRadius(14)
            .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
            .border({ width: 1, color: this.tc('#D3DAE4', '#2E2E34') })
            .shadow({ radius: 14, color: this.tc('#26000000', '#00000000'), offsetX: 0, offsetY: 3 })
          }

          // 说明卡片
          Column({ space: 6 }) {
            Text('备份文件')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.tc('#2B2B2B', '#E6E6E9'))
              .width('100%')
            Text('· 主文件：' + DAV_DIR + DAV_FILE + '（固定名，可在浏览器直接下载）')
              .fontSize(11)
              .fontColor(this.tc('#777777', '#A6A6AE'))
              .width('100%')
            Text('· 副本：' + DAV_DIR + '/dsh-sites-<时间戳>.json（每次备份留一份历史）')
              .fontSize(11)
              .fontColor(this.tc('#777777', '#A6A6AE'))
              .width('100%')
            Text('· 内容含系统、地址、账号密码（自动登录用），请妥善保管该目录权限。')
              .fontSize(11)
              .fontColor(this.tc('#CC6633', '#E08A5A'))
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .borderRadius(14)
          .backgroundColor(this.tc('#FFFFFF', '#1C1C20'))
          .border({ width: 1, color: this.tc('#D3DAE4', '#2E2E34') })
          .shadow({ radius: 14, color: this.tc('#26000000', '#00000000'), offsetX: 0, offsetY: 3 })
          .margin({ bottom: 20 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.contentW() })
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, bottom: this.safeBottom })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.tc('#DFE4EB', '#111114'))
  }

  build() {
    Stack() {
      Column() {
        Web({ src: EMPTY_URL, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        // 回车=换行（必须在文档开始注册，才能抢在 DSH 的处理器之前）
        .javaScriptOnDocumentStart([
          // 上下文图片：点击就拦（官方不打开）
          { script: CONTEXT_IMG_JS, scriptRules: ['*'] },
          // 回车=换行（必须在文档开始注册，才能抢在 DSH 的处理器之前）
          { script: ENTER_AS_NEWLINE_JS, scriptRules: ['*'] }
        ])
        // 声明系统软键盘的回车键类型为「换行」(NEWLINE)。
        // ★这里踩过两次：
        //   ① 不声明（UNSPECIFIED）→ 输入框上一直显示"发送"，小艺的长按换行无效。
        //   ② 声明成 SEND → 强制显示"发送"、行为固定为发送，长按换行**依然无效**。
        // 用户实测对照：微信/QQ 里"小艺长按发送键换行"关闭时**显示换行**、开启时**显示发送且长按换行**
        //   —— 说明应用应当声明"换行"，由输入法按它自己的开关去升级成"发送+长按换行"。
        // 所以这里声明 NEWLINE：关闭该功能时就是普通的换行键（能换行），
        // 开启后由输入法升级为发送键并支持长按换行。
        .onInterceptKeyboardAttach((info: WebKeyboardCallbackInfo) => {
          const opts: WebKeyboardOptions = {
            useSystemKeyboard: true,
            enterKeyType: inputMethod.EnterKeyType.NEWLINE
          };
          return opts;
        })
        .imageAccess(true)
        .fileAccess(true)
        .mediaPlayGestureAccess(true)
        .mixedMode(MixedMode.All)
        .zoomAccess(false)
        .javaScriptProxy({
          object: this.buildBridge(),
          name: 'dshShell',
          methodList: ['getGroups', 'getCurrent', 'saveGroups', 'switchTo', 'getSafeTop', 'getSafeBottom', 'log', 'openSites', 'setOverlay', 'setFileFix', 'openFile', 'setDark', 'setDialog', 'getCurLabel', 'openSwitcher', 'dbg'],
          controller: this.controller
        })
        .onHttpAuthRequest((event: OnHttpAuthRequestEvent) => {
          if (event) {
            const g = this.groups[this.curG];
            const a = (g && g.items && g.items[this.curI]) ? g.items[this.curI] : null;
            if (a && a.user && a.user.length > 0) {
              this.addLog('自动填写服务器认证');
              this.lastErr = 'AUTH-OK';
              event.handler.confirm(a.user, a.pass);
            } else {
              this.lastErr = 'AUTH-NOCRED';
              event.handler.cancel();
            }
          }
          return true;
        })
        .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
          if (event) {
            this.addLog('忽略证书错误');
            // 累积而不是覆盖：便于区分"SSL 被忽略后仍失败"与"纯网络失败"
            this.lastErr = 'SSL';
            this.sslIgnored = true;
            event.handler.handleConfirm();
          }
        })
        .onTitleReceive((event) => {
          // 标题变化 = 切换了会话。DSH 这时会自动聚焦输入框并弹输入法，我们立刻并延迟各收一次，
          // 因为它的聚焦动作可能发生在我们之后。
          this.dismissKeyboard();
          setTimeout(() => {
            this.dismissKeyboard();
          }, 250);
          setTimeout(() => {
            this.dismissKeyboard();
          }, 700);
        })
        .onProgressChange((event) => {
          // 判定要"宽进"：之前要求 100% 且 !loadFailed，导致 https+认证类站点被误判成
          // "一直转圈→连不上"，而页面其实早就显示出来了（用户侧滑返回能看到真实状态）。
          if (event && event.newProgress >= 90) {
            this.dismissKeyboard();
            if (this.phase === PHASE_LOADING) {
              this.markLink(this.curG, this.curI, 'ok');
              this.phase = PHASE_WEB;
              this.watchWhiteScreen();
              this.visited = true;
              this.saveStore();
              this.clearWebHistory();
            }
          }
        })
        // 诊断：把网页控制台里的报错抓下来存成状态，直接显示在界面上
        // （真机排查时不用连电脑就能取证）
        .onConsole((event) => {
          try {
            if (event && event.message) {
              if (true) {
                const one = '[' + event.message.getSourceId() + ':'
                  + event.message.getLineNumber().toString() + '] '
                  + event.message.getMessage();
                this.webConsoleErr = one.length > 240 ? one.substring(0, 240) : one;
              }
            }
          } catch (e) {
          }
          return true;
        })
        .onPageEnd(() => {
          if (this.phase === PHASE_LOADING) {
            // 同样不再因 loadFailed 拒绝切页：页面能显示就该让用户看到，
            // 真的打不开时网页自己会给出错误内容。
            this.markLink(this.curG, this.curI, 'ok');
            this.phase = PHASE_WEB;
              this.watchWhiteScreen();
            this.visited = true;
            this.saveStore();
            this.clearWebHistory();
          }
          // 上报左侧栏实时宽度，让状态栏双色块跟随（收起/展开都要跟）
          this.injectAll();
        })
        .onErrorReceive((event) => {
          if (event) {
            const code = event.error.getErrorCode();
            this.addLog('加载错误 ' + code);
            this.lastErr = 'E' + code.toString();
            if (code !== -3 && this.phase === PHASE_LOADING) {
              this.loadFailed = true;
              this.setErr(this.curG, this.curI, 'E' + code.toString());
            }
          }
        })
        .onShowFileSelector((event: OnShowFileSelectorEvent) => {
          const fileSelectorResult: FileSelectorResult = event.result;
          try {
            const options = new picker.PhotoSelectOptions();
            options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
            options.maxSelectNumber = 1;
            const photoPicker = new picker.PhotoViewPicker();
            photoPicker.select(options).then((result: picker.PhotoSelectResult) => {
              if (result && result.photoUris && result.photoUris.length > 0) {
                fileSelectorResult.handleFileList(result.photoUris);
              } else {
                fileSelectorResult.handleFileList([]);
              }
            }).catch((err: BusinessError) => {
              fileSelectorResult.handleFileList([]);
            });
          } catch (err) {
            fileSelectorResult.handleFileList([]);
          }
          return true;
        })
        .width('100%')
        .height('100%')
        // 不再向上扩展安全区：向上扩展会让网页内容整体上顶（logo 会被状态栏块盖住），
      // 状态栏那一块改由上面的双色 Row 负责填充。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .padding({ top: this.safeTop })
      }
      .width('100%')
      .height('100%')
      // 让网页从状态栏下方开始渲染：否则网页顶部内容会被状态栏双色块盖住
      //（表现就是 logo 和侧栏切换按钮"消失"）。这是布局级下移，和 Web.padding 不同。
      .padding({ top: this.safeTop })

      // 隐藏的探测 Web（后台依次真加载每条地址）
      Web({ src: EMPTY_URL, controller: this.probeController })
        .javaScriptAccess(true)
        .width(1)
        .height(1)
        .opacity(0)
        .onHttpAuthRequest((event: OnHttpAuthRequestEvent) => {
          if (event) {
            const g = this.groups[this.probeG];
            const a = (g && g.items && g.items[this.probeI]) ? g.items[this.probeI] : null;
            if (a && a.user && a.user.length > 0) {
              event.handler.confirm(a.user, a.pass);
            } else {
              this.lastErr = 'AUTH-NOCRED';
              event.handler.cancel();
            }
          }
          return true;
        })
        .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
          if (event) {
            this.probeSslIgnored = true;
            event.handler.handleConfirm();
          }
        })
        .onPageEnd(() => {
          this.onProbeEnd();
        })
        .onErrorReceive((event) => {
          if (event) {
            const c = event.error.getErrorCode();
            if (c !== -3) {
              this.probeHadError = true;
            }
          }
        })


      // 状态栏区域**不再单独画色条**（用户定稿）。
      // 窗口是 setWindowLayoutFullScreen(true)，所以状态栏那一条露出来的
      // 就是根 Stack 的背景色（见 build() 末尾的
      // .backgroundColor(this.tc('#FFFFFF', '#151517'))）——
      // 也就是"页面背景自然延伸上去"，和以前的表现一致。
      // 网页内容靠外层 Column 的 .padding({ top: this.safeTop }) 下移，不会跑到状态栏上面。

      // 站点快速切换面板（点左侧栏那行"当前连接情况"时弹出）
      if (this.showSwitcher) {
        Column() {
          Blank()
            .onClick(() => {
              this.showSwitcher = false;
            })
          this.SwitcherSheet()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.25)')
      }

      // 左侧栏的「当前连接情况」由注入脚本插进网页 DOM（见 injectAll 的 ⑥）：
      // 这样它属于网页层级、设置弹窗能正常盖住它，收起导航栏时也会跟着收。

      if (this.phase === PHASE_LOADING) {
        this.LoadingPage()
      } else if (this.phase === PHASE_PICKER) {
        if (this.panelMode === 'edit') {
          this.EditPage()
        } else if (this.panelMode === 'backup') {
          this.BackupPage()
        } else {
          this.PickerPage()
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.TopStart)
    // 状态栏那一条露出的就是这里的背景色（窗口全屏布局），所以这里等于"页面底色延伸上去"。
    // 深色值取 DSH 深色主题的对话区底色（#151517），和网页顶部天然接得上。
    .backgroundColor(this.tc('#FFFFFF', '#151517'))
    // 记录窗口宽度，供折叠屏断点适配使用（外屏≈540vp / 内屏≈782vp）
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = Number(newV.width);
      if (!isNaN(w) && w > 0 && Math.abs(w - this.winW) > 2) {
        this.winW = w;
      }
    })
  }
}
