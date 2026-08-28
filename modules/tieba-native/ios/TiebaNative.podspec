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
  s.swift_version  = '5.9'
  s.source         = { :path => '.' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.frameworks = ['BackgroundTasks', 'Security', 'ImageIO', 'CoreGraphics', 'UIKit']
  s.libraries = 'sqlite3'

  s.source_files = "**/*.{h,m,swift}"
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
