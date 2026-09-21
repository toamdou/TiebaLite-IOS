<div align="center">

# 贴吧 Lite · TiebaLite for iOS

**第三方百度贴吧 iOS 客户端** — 纯 Swift / UIKit（零 JS、零 RN）；iOS 26+ 走液态玻璃，
**iOS 17/18 退回该系统年代的常规材质与底栏形态**（本分支 = 最低版本 17.0）

[![Build iOS Unsigned IPA](https://github.com/toamdou/TiebaLite-IOS/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/toamdou/TiebaLite-IOS/actions/workflows/build-ipa.yml)
![Version](https://img.shields.io/badge/version-2.0.0-208AEF)
![Platform](https://img.shields.io/badge/platform-iOS%2016.4%2B-208AEF)
![License](https://img.shields.io/badge/License-GPLv3-blue.svg)
![Stack](https://img.shields.io/badge/Swift%206%20%C2%B7%20UIKit-native-blue)

<!-- ═══════════ 真机演示图 ═══════════
     截图放 docs/screenshots/，覆盖同名文件即可更新：
     home.png（关注页）/ explore.png（动态页）/ profile.png（我的页）/ settings.jpg（设置页） -->
<img src="docs/screenshots/home.png" width="24%" alt="关注页" />
<img src="docs/screenshots/explore.png" width="24%" alt="动态页" />
<img src="docs/screenshots/profile.png" width="24%" alt="我的页" />
<img src="docs/screenshots/settings.jpg" width="24%" alt="设置页" />

</div>

---

## ✨ 功能一览

### ✅ 已实现

**浏览**

- ✅ 关注页：关注吧列表、最近访问、关注吧动态
- ✅ 动态页：推荐 / 关注 / 热榜
- ✅ 吧页：分类浏览、排序、吧资料、单吧签到、关注 / 取关
- ✅ 帖子页：楼层列表、楼中楼（子回复）、父回复引用、楼层排序
- ✅ 搜索：吧 / 帖 / 人
- ❓ 消息中心：回复我的 / 提到我的（未经测试，可能存在Bug）
- ✅ 用户主页：资料与发帖浏览
- ✅ 历史记录与收藏夹

**互动**

- ✅ 登录：百度通行证 WebView 授权
- ✅ 点赞 / 取消点赞（帖子、楼层）
- ✅ 收藏 / 取消收藏帖子
- ✅ 一键签到：批量吧签到 + 灵动岛 Live Activity 实时进度

**体验**

- ✅ 深色模式（含 AMOLED 纯黑）
- ✅ 顶栏 / 底栏与原生转场（iOS 26+ 为液态玻璃；17–25 为系统常规材质）
- ✅ 触感反馈
- ✅ 图片查看器
- ✅ 视频播放
- ✅ 广告 / 直播内容过滤
- ❓ 屏蔽：屏蔽词 / 屏蔽用户 / 屏蔽吧
- ✅ 阅读字号、省流量模式、图片加载质量三档
- ✅  App scheme 深链

### ❌ 未实现

- ❌ 发帖 / 回复 / 楼中楼发言 —— 只读 + 轻互动，无法发言
- ❌ 私信
- ❌ 推送通知（应用不带推送权限）
- ❌ 直播观看（信息流中已过滤）
- ❌ 投票等帖子内互动插件
- ❌ iPad 适配（仅 iPhone 竖屏）

## 📁 项目结构

```
TiebaLite/                  App 目标：入口、Info.plist、资源、Icon Composer 图标
Extensions/TiebaLiveActivity/ 灵动岛小组件扩展（独立 target）
Sources/TiebaNative/        主模块（唯一 Swift module，按功能分区）
  App/                        引导、会话、路由与导航壳、深链、更新
  Core/                       存储（SQLite/KV/Keychain/Cookie）、偏好、后台任务、触觉、几何
    Networking/               所有 HTTP API 客户端
    Proto/                    protobuf 编解码、视图模型映射、生成代码
  UI/                         Chrome（顶栏/底栏）、通用控件、原生行列表、图片与查看器
  Features/                   按页面分：Home / Explore / Forum / Thread / Search
                              / Profile / Messages / Settings / Auth / Web
Vendor/                     源码内嵌的第三方库（Nuke、JXPhotoBrowser、SwiftProtobuf）
Signing/                    设备签名描述文件（内容不入库，CI 现场生成占位件）
Tools/                     占位描述文件生成、产物隐私清洗
```

构建入口与标签：`bazel build //:App`，主模块 `//Sources/TiebaNative:TiebaNative`。

## 🛠 本地编译

### 环境要求

| 依赖 | 要求 |
| --- | --- |
| macOS | 14+ |
| Xcode | 26 或更高（开发环境为 Xcode 27 beta） |
| 最低 iOS | 17.0（≥26 用 Icon Composer 图标，<26 用 AppIcon.appiconset） |
| [Bazelisk](https://github.com/bazelbuild/bazelisk) | `brew install bazelisk`（版本由 `.bazelversion` 锁定） |
| Apple ID | 免费个人 Apple ID 即可真机调试 |

### 步骤

```bash
git clone https://github.com/toamdou/TiebaLite-IOS.git
cd TiebaLite-IOS

# 模拟器编译+运行（无需签名）
bazel build //:App --config=sim

# 真机：把自己的描述文件放进 Signing/ 后（app 与扩展各一份）
bazel build //:App --config=device --config=sign

# 需要 Xcode 断点调试时：先用 Bazel 生成工程，再打开
bazel run //:xcodeproj && open xcodeproj.xcodeproj
```

> 可选：把 Bazel 缓存路径写进 `.bazelrc.user`（已 gitignore，含本机绝对路径），可大幅加速重复编译。

在 Xcode 中：

1. 选中 `tiebalite` target → **Signing & Capabilities** → 勾选你自己的 Team（免费个人 Apple ID 即可）；
2. 若 Bundle Identifier `com.tiebalite.app` 与你的签名冲突，改成自己的（如 `com.yourname.tiebalite`）；
3. 选择你的 iPhone 真机 → **⌘R** 编译运行。


## 🤖 GitHub Actions 自动打包（未签名 IPA）

仓库自带工作流 [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml)：在 GitHub 的 macOS runner 上用 Bazel 出真机 arm64 产物（ad-hoc 身份 = 无签名口径）并打包 `.ipa`。

**两种触发方式：**

1. **手动构建**：仓库页 → **Actions** → **Build iOS Unsigned IPA** → **Run workflow**（可选 Release / Debug）→ 结束后在本次运行页面的 Artifacts 下载 `TiebaLite-unsigned-*.ipa`；
2. **打 Tag 自动发 Release**：

## 📱 通过 SideStore / AltStore 安装

CI 产出的是**未签名 IPA**，不能直接安装，需要 SideStore / AltStore 用你自己的 Apple ID 重签后侧载：

免费 Apple ID 的限制：签名 **7 天有效**（SideStore 可自动刷新）、最多同时签 **3 个 App**、部分能力（推送 / App Groups 等）不可用。

## 🙏 致谢

本项目站在这些项目的肩膀上：

- [HuanCheng65/TiebaLite](https://github.com/HuanCheng65/TiebaLite) — Kotlin 原版
- [zzc10086/TiebaLite](https://github.com/zzc10086/TiebaLite) — Kotlin 版 fork
- [Starry-OvO/aiotieba](https://github.com/Starry-OvO/aiotieba) — 贴吧协议字段参考
- [n0099/tbclient.protobuf](https://github.com/n0099/tbclient.protobuf) — 百度贴吧客户端 protobuf 定义合集

## 📄 许可证

本项目以 [GPL-3.0](LICENSE) 协议开源。

## ⚠️ 免责声明

本软件及源码**仅供学习交流使用，严禁用于商业用途**。本项目与百度官方无关，贴吧相关 API 与数据版权归百度所有，使用本项目产生的一切后果由使用者自行承担。
