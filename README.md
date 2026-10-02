# Dsh-Web_hap

**Dsh 鸿蒙版** —— 一个 HarmonyOS（ArkTS + ArkWeb）的 **WebView 多站点壳应用**，
把多个自建 Web 系统装进一个 App 里，快速切换、自动登录、并为折叠屏做了适配。

> 本仓库**不预置任何站点**。首次打开是空的，请自行添加，或用内置的 WebDAV 备份恢复。

---

## 功能

### 多站点管理
- 站点分两级：**系统**（如「家里」「公司」）→ **多条地址**
- 每条地址可设**备注名、网址、账号、密码**，可单独**停用**
- 系统名 / 地址可改；系统和地址都支持**排序**（站点页右上角「排序」）
- 每条地址带**连通状态灯**：绿=可打开、橙=打不开、灰=没测过、🔑=已配账号
- 点地址即连接；点不通会给出原因（超时 / 白屏 / SSL / 认证失败），不会卡死

### 快速切换
- 你的站点配置会**注入到网页左侧栏**（「当前连接情况」那一行），点它弹出**底部切换面板**，
  按系统分组列出所有**未停用**地址，当前项高亮，点一条即切换
- App 会**记住上次进入的站点**，下次打开直接回到那里

### 自动登录
- 地址配了账号密码时，进入登录页会**自动填入并提交**（进入后 1.5s / 3.5s 各尝试一次）
- 凭据只存在**手机本地 preferences**，不写进源码、不写进安装包

### WebDAV 备份 / 恢复（推荐开启）
- 站点页底部 →「☁ WebDAV 站点备份 / 恢复」
- 备份目录固定为 **`<你的 WebDAV 根>/DSH/Dsh_zhandian`**，**首次备份自动创建**
- 生成两个文件：
  - `dsh-sites.json` —— 固定名，**可直接在浏览器里下载**
  - `dsh-sites-<时间戳>.json` —— 每次备份留一份历史副本
- 支持**自动备份**：站点有改动时延迟 8 秒自动上传（防抖）
- 换机 / 重装后一键「从备份恢复」
- ⚠️ 备份内容**含账号密码**，请确保该目录的访问权限设置正确

### 折叠屏适配
- 按 **Material Design 3 的 Window Size Classes** 做响应式断点：
  | 窗口宽度 | 档位 | 处理 |
  |---|---|---|
  | < 600vp | Compact（外屏） | 单列，内容铺满 |
  | 600–840vp | Medium（内屏展开） | 内容限宽 680vp 居中 |
  | > 840vp | Expanded | 内容限宽 760vp 居中 |
- 避免大屏上每行文字被拉得过长
- 未使用"平行视界"：那是给原生双栏应用的，WebView 壳硬开会出现两个界面

### 其他
- **状态栏双色**：左侧与网页侧栏同色、右侧与对话区同色，中间一条 1px 分界线对齐
- 原生「站点」选项卡会插进网页的设置弹窗里，与网页设置融为一体
- 返回键两段式退出（再按一次退出），避免误触

---

## 编译

**环境**：DevEco Studio（HarmonyOS SDK），`compatibleSdkVersion 6.1.1(24)`

```bash
# 在项目根目录
hvigorw assembleHap --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
```

**关于签名**：本仓库的 `build-profile.json5` **不含签名配置**（证书路径和口令是每台机器私有的）。
请用 DevEco Studio 的 *File → Project Structure → Signing Configs* 自动生成，或自行填入你的证书。

安装到设备：
```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

---

## 项目结构

```
AppScope/                     应用级配置（bundleName、图标、名称）
entry/src/main/
  ets/pages/Index.ets         全部界面与逻辑（单文件）
  ets/entryability/           入口 Ability
  resources/                  图标、字符串、颜色
signature/                    签名材料（已在 .gitignore 排除）
```

`Index.ets` 是核心，包含：
- 状态机 `PHASE_PICKER / PHASE_LOADING / PHASE_WEB`
- 站点数据模型 `Group` / `Address`
- 站点页 `PickerPage`、编辑页 `EditPage`、备份页 `BackupPage`、切换面板 `SwitcherSheet`
- WebDAV 客户端（基于 `@kit.NetworkKit` 的 http，`MKCOL`/`PUT`/`GET`）
- 网页增强注入 `injectAll()`（自动登录、状态上报、侧栏插入等）

---

## 已知限制

- **长按拖拽排序不工作**：ArkWeb 容器里 `List` 的 `onItemDragStart/onItemDrop` 实测不触发，
  因此排序统一用「上移 / 下移」按钮
- 网页里的某些引导弹窗无法自动关闭（依赖对方 DOM），需要手动点一次
- 自动登录依赖登录页的 DOM 结构，若目标站点改版可能需要调整注入脚本
- WebDAV 走 **HTTP Basic** 认证；若服务端只允许 Digest/NTLM 则无法使用

---

## 许可

未指定许可证。如需开源协议请自行添加。
