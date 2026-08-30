require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'TiebaNative'
  s.version        = package['version']
  s.summary        = 'TiebaLite native performance modules'
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'TiebaLite'
  s.homepage       = 'https://github.com/tiebalite/tieba-native'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.0'
  s.source         = { :path => '.' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.dependency 'SwiftProtobuf', '~> 1.28'
  # 生成代码（ProtoGenerated/）已拆到独立 pod TiebaProtoGenerated
  #（modules/tieba-proto/ios，267 文件预编译为静态库，日常增量不再整批重编）
  s.dependency 'TiebaProtoGenerated'

  s.frameworks = ['BackgroundTasks', 'Security', 'ImageIO', 'CoreGraphics', 'UIKit']
  s.libraries = 'sqlite3'

  # 排除生成代码（已移入 ../tieba-proto/ios/ProtoGenerated）
  s.source_files = "**/*.{h,m,swift}", "!ProtoGenerated/**/*"
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
