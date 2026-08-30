require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', '..', '..', 'package.json')))

# TiebaProtoGenerated — protoc-gen-swift 生成的 267 个 proto 消息文件
# （只读生成物：字段变化需重跑 protos 生成脚本；日常增量不触碰本 pod，
# 独立 target 后 App 编译不再整批重编 267 文件 —— 2026-08-30 拆分）。
Pod::Spec.new do |s|
  s.name           = 'TiebaProtoGenerated'
  s.version        = package['version']
  s.summary        = 'Generated SwiftProtobuf messages for TiebaLite'
  s.license        = package['license']
  s.author         = 'TiebaLite'
  s.homepage       = 'https://github.com/tiebalite/tieba-proto'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.0'
  s.source         = { :path => '.' }
  s.static_framework = true

  s.dependency 'SwiftProtobuf', '~> 1.28'

  s.source_files = "ProtoGenerated/**/*.swift"
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end