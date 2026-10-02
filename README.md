# Dsh-Web_hap

**Dsh 鸿蒙版** —— 一个 HarmonyOS（ArkTS + ArkWeb）的 **WebView 多站点壳应用**，
把多个自建 Web 系统装进一个 App 里，快速切换、自动登录、并为折叠屏做了适配。

> 当前版本：**v1.1（稳定版）** · `versionCode 1001000`
> 本仓库**只发布未签名包**（用 hokit 安装）。**不预置任何站点** —— 首次打开是空的，
> 请自行添加，或用内置的 WebDAV 备份恢复。

---

## 功能

### 多站点管理
- 站点分两级：**系统**（如「家里」「公司」）→ **多条地址**
- 每条地址可设**备注名、网址、账号、密码**，可单独**停用**
- 系统名 / 地址可改；系统和地址都支持**排序**（站点页右上角「排序」）
- 每条地址带**连通状态灯**：绿=可打开、橙=打不开、灰=没测过、🔑=已配账号
- 点地址即连接；点不通会给出原因（超时 / 白屏 / SSL / 认证失败），不会卡死
- **不再开机自动探测**：不点的地址没必要探，「点了打不开要能退回来」由白屏兜底负责；
  想看全部状态灯时在站点页手动点「**重新检测**」；**一旦退出站点页立即取消探测**

### 快速切换
- 你的站点配置会**注入到网页左侧栏**（「当前连接情况」那一行），点它弹出**底部切换面板**，
  按系统分组列出所有**未停用**地址，当前项高亮，点一条即切换
- App 会**记住上次进入的站点**，下次打开直接回到那里

### 自动登录
- 地址配了账号密码时，进入登录页会**自动填入并提交**（进入后 1.5s / 3.5s 各尝试一次）
- 凭据只存在**手机本地 preferences**，不写进源码、不写进安装包

### 内置文件查看器（本项目特有）
DSH 网页版自带的文件查看器在 HarmonyOS 的 **ArkWeb** 环境里打不开（原因见「已知限制」），
本 App 因此**自带一个**：

- 点文件树里的文件 → DSH 报「文件资源服务不可用」→ 本 App **自动接管并显示内容**
- 点击时**立刻预取**内容，错误一出现即渲染（基本无感）
- 仿网页版排版：等宽字体、绝对路径条、`自动换行 / 取消换行`（状态高亮可见）、
  `重新读取`、`关闭`；长文件底部有 `加载更多`
- 自动跟随深色主题
- 显示后**自动关掉网页版那个报错页签**，页签栏不会堆积
- 关闭方式：**左边缘右滑** / **系统返回键**

### WebDAV 备份 / 恢复（推荐开启）
- 站点页底部 →「☁ WebDAV 站点备份 / 恢复」
- 备份目录固定为 **`<你的 WebDAV 根>/DSH/Dsh_zhandian`**，**首次备份自动创建**
- 生成两个文件：
  - `dsh-sites.json` —— 固定名，**可直接在浏览器里下载**
  - `dsh-sites-<时间戳>.json` —— 每次备份留一份历史副本
- 支持**自动备份**：站点有改动时延迟 8 秒自动上传（防抖）；**默认关闭**
- 换机 / 重装后一键「从备份恢复」
- ⚠️ 备份内容**含账号密码**，请确保该目录的访问权限设置正确

### 折叠屏适配
- 按 **Material Design 3 的 Window Size Classes** 做响应式断点：

  | 窗口宽度 | 档位 | 处理 |
  |---|---|---|
  | < 600vp | Compact（外屏） | 单列，内容铺满 |
  | 600–840vp | Medium（内屏展开） | 内容限宽 680vp 居中 |
  | > 840vp | Expanded | 内容限宽 760vp 居中 |

- 展开态下右侧栏是**常驻分栏**，侧滑返回**不会**把它收起来（只有折叠态才收）
- 未使用「平行视界」：那是给原生双栏应用的，WebView 壳硬开会出现两个界面

### 状态栏
- 窗口全屏布局（`setWindowLayoutFullScreen(true)`），状态栏那一条露出的就是**根容器背景**
  —— 即"页面底色自然延伸上去"，**不是单独画的色条**
- 明暗**跟随 DSH 主题**（由网页上报一个布尔值 `setDark`），系统状态栏图标颜色同步切换

### 返回键
按优先级依次：**关文件查看器 → 关网页弹窗 → 收右侧栏（仅折叠态）→ 两段式退出**。

---

## 编译

**环境**：DevEco Studio（HarmonyOS SDK），`compatibleSdkVersion 6.1.1(24)`

```bash
# 在项目根目录
hvigorw assembleHap --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

**关于签名**：本仓库的 `build-profile.json5` **不含签名配置**，因此构建产物是**未签名**的
（`signingConfigs: []`），与发布包一致。这既保证了仓库里不含任何证书材料，
也让"仓库里的代码"与"发布的包"能一一对应。

如需在真机上用 `hdc install` 安装，请自行用 DevEco Studio 的
*File → Project Structure → Signing Configs* 自动签名（需要你的华为账号与设备白名单）。

---

## 项目结构

```
AppScope/                     应用级配置（bundleName、图标、名称、版本号）
entry/src/main/
  ets/pages/Index.ets         全部界面与逻辑（单文件）
  ets/entryability/           入口 Ability
  resources/                  图标、字符串、颜色
```

`Index.ets` 是核心，包含：
- 状态机 `PHASE_PICKER / PHASE_LOADING / PHASE_WEB`
- 站点数据模型 `Group` / `Address`
- 站点页 `PickerPage`、编辑页 `EditPage`、备份页 `BackupPage`、切换面板 `SwitcherSheet`
- WebDAV 客户端（`MKCOL` 用 `@kit.RemoteCommunicationKit` 的 `rcp`，
  因为 `http.RequestMethod` 是封闭枚举、不含 `MKCOL`；`PUT`/`GET`/`DELETE` 仍走 `http` 以保留进度事件）
- 网页增强注入 `injectAll()`（自动登录、状态上报、侧栏插入等）
- **内置文件查看器** `injectFileFix()`（见下）

---

## 已知限制

### 网页版文件查看器在 ArkWeb 里不可用（本 App 已自行绕过）
DSH 的 `file` 资源提供方是**依赖注入式**注册：
「浏览器导出向 `ctx.resources` 注册 `file` 提供方，要求 `resources`、`remote`、
`remote.workspaceFiles` 三者在场」——**缺一个就根本不注册**，
于是 `dsh-resource://file/…` 一律返回 `none`，**且一个请求都不发**。

- 对照证据：`dsh-resource://changes-review/…`（变更审查 / diff）在 ArkWeb 里**正常**，
  说明资源机制本身没坏，**只有 `file` 这一类提供方缺失**
- 同一台手机用 Edge（Chromium）打开同一地址**完全正常** → 属引擎环境差异
- 已逐条实测排除：文件不存在、注入脚本、JS 报错、窄屏、缺新 Web API、UA 平台判断、
  插件未加载、Web 组件属性（9 处）、资源机制整体故障
- **本 App 的解法**：不依赖它，改为同源直调 `POST /api/workspaceFiles/read`
  并自行渲染（即上面的「内置文件查看器」）

### 其他
- **长按拖拽排序不工作**：ArkWeb 容器里 `List` 的 `onItemDragStart` / `onItemDrop` 实测不触发，
  因此排序统一用「上移 / 下移」按钮
- 网页里的某些引导弹窗无法自动关闭（依赖对方 DOM），需要手动点一次
- 自动登录依赖登录页的 DOM 结构，若目标站点改版可能需要调整注入脚本
- **内置文件查看器**同理：它读的是 DSH 的页面 DOM（会话标识取自 `[data-sidebar-right-session]`），
  DSH 前端大改后可能需要同步调整
- WebDAV 走 **HTTP Basic** 认证；若服务端只允许 Digest / NTLM 则无法使用

---

## 许可

未指定许可证。如需开源协议请自行添加。
