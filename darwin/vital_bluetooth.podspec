#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vital_bluetooth.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vital_bluetooth'
  s.version          = '0.0.1'
  s.summary          = 'Reliable Bluetooth LE and Classic plugin for wearables and healthcare devices.'
  s.description      = <<-DESC
Reliable Bluetooth LE and Classic plugin for wearables and healthcare devices,
with queued GATT operations, auto-reconnect and multi-device support.
                       DESC
  s.homepage         = 'https://github.com/AnChiyoung/vital_bluetooth'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'AnChiyoung' => 'dev.goodluckcy@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'vital_bluetooth/Sources/vital_bluetooth/**/*.swift'
  s.resource_bundles = { 'vital_bluetooth_privacy' => ['vital_bluetooth/Sources/vital_bluetooth/PrivacyInfo.xcprivacy'] }

  # iOS and macOS share one Swift source tree (sharedDarwinSource in pubspec.yaml).
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.frameworks = 'CoreBluetooth'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
