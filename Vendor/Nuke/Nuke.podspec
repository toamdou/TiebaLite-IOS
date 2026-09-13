Pod::Spec.new do |s|
  s.name             = 'Nuke'
  s.version          = '13.2.0'
  s.summary          = 'Image loading system'
  s.description      = <<-DESC
vendor 的 Nuke 13.2.0 源码。Nuke 12/13 官方没有 podspec（CocoaPods trunk 只到 10.7.1，
12.x 起只发 SPM 与 GitHub Release 的 xcframework），而本仓的图片加载代码位于 TiebaNative
pod 内部，pod target 无法依赖 SPM 产物，故把官方源码 vendor 进仓库、用本地 podspec 由本方
工具链编译（静态 framework，无条件分发/嵌入问题，也不需要 xcframework 的嵌入阶段）。

来源：https://github.com/kean/Nuke  tag 13.2.0（MIT，见同目录 LICENSE）。
升级方式：替换 Sources/ 两个目录 + 改这里的 version，然后 pod install。

⚠️ 版本必须钉在 13.2.0（不是 13.0.0–13.0.5）：13.0.6 之前的版本在 Swift 5/6 语言模式
交界处有 dynamic actor isolation 崩溃（官方 release notes），本仓虽然全量走 Swift 6 语言
模式，仍按上游建议取最新 13.x。

⚠️ Nuke 13 是围绕 @ImagePipelineActor 全局 actor + TaskQueue 设计的：整套并发保证
（ImagePipeline/ImageTask/AsyncTask 的隔离）只在 Swift 6 语言模式下被编译器检查。以
Swift 5 语言模式编译 Nuke 13 能过，但隔离检查会被静默关闭——所以本 pod 声明
swift_versions = ['6.0']，且 app target 也必须是 Swift 6（见 ios/tiebalite.xcodeproj 的
SWIFT_VERSION 与 ios/Podfile post_install 的说明）。

平台：Nuke 13 的 floor 是 iOS 15（见 Package.swift platforms），app 自身是 iOS 16.4。

注意：Nuke 13.2.0 不含 PrivacyInfo.xcprivacy，无需参与隐私清单聚合。
  DESC
  s.homepage         = 'https://github.com/kean/Nuke'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Alexander Grebenyuk' => 'https://github.com/kean' }
  s.platform         = :ios, '15.0'
  s.source           = { :path => '.' }

  # ⚠️ 更正（2026-09-13，实测）：**subspec 不会各自成为独立模块**。
  # CocoaPods 的 analyzer 按 root spec 归组，PodTarget#product_module_name 取
  # root_spec.module_name——本地实证：27 个 React-Fabric/* subspec 只生成
  # 一个 PBXNativeTarget "React-Fabric"，14 个 React-Core/* 同理。
  # 所以 Nuke/Core + Nuke/Extensions 会一起编进**同一个 `Nuke` 模块**，
  # `import NukeExtensions` 永远不会成立（import Nuke 即可拿到 loadImage）。
  # 真要两个模块，得再拆一个独立 podspec（如 vendor/Nuke/NukeExtensions.podspec）
  # 并单独声明依赖。此处保留 subspec 只是为了让 Extensions 的源码参与编译。
  # 2026-09-13：Core 与 Extensions **两个都在用**。
  #   Nuke/Core       —— 管线本体（请求组装/缓存/预取/Referer 注入/降档处理器）
  #   Nuke/Extensions —— Nuke 官方的 UIImageView 集成（loadImage(with:options:
  #                      into:progress:completion:)），负责：换图前取消在途请求、
  #                      占位图/失败图/过渡动画、对视图的弱引用（视图销毁自动取消）。
  # 为什么必须带上 Extensions：这些正是最容易手写出错的地方（本仓已经踩过
  # "复用行重放 transition 淡入""换图不取消旧请求"两次）。能用 Nuke 自己的
  # 实现就不要自己写一遍。
  s.subspec 'Core' do |c|
    c.source_files = 'Sources/Nuke/**/*.swift'
  end

  s.subspec 'Extensions' do |e|
    e.source_files = 'Sources/NukeExtensions/**/*.swift'
    e.dependency 'Nuke/Core'
  end

  s.default_subspec = 'Core'
  # Swift 6 语言模式：Nuke 13 的 actor 隔离设计需要它（见上）。
  s.swift_versions = ['6.0']
end
