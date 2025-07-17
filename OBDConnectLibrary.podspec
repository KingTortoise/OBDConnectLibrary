
# OBDConnectLibrary.podspec
Pod::Spec.new do |s|
  s.name             = 'OBDConnectLibrary'
  s.version          = '1.0.4'
  s.summary          = 'A Swift library for OBD communication.'
  s.description      = <<-DESC
                        OBDConnectLibrary provides a simplified API for interacting
                        with Bluetooth LE devices and external accessories.
                       DESC
  s.homepage         = 'https://github.com/KingTortoise/OBDConnectLibrary'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'wenwujin' => '810270355@qq.com' }
  s.source           = { :git => 'https://github.com/KingTortoise/OBDConnectLibrary.git', :tag => s.version.to_s }

  # 平台支持
  s.ios.deployment_target = '14.0'
  s.swift_version = '5.7'

  # 源代码位置
  s.source_files = 'Sources/OBDConnectLibrary/*.swift'

  # 系统框架依赖
  s.frameworks = 'CoreBluetooth', 'ExternalAccessory'
  
  # 如果需要在 Info.plist 中添加权限描述
  s.user_target_xcconfig = {
    'SWIFT_VERSION' => '5.7',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) COCOAPODS=1',
    'INFO_PLIST_FILE' => '$(SRCROOT)/Pods/Target Support Files/OBDConnectLibrary/OBDConnectLibrary-Info.plist'
  }
  
end
