#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_classic_bluetooth.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_classic_bluetooth'
  s.version          = '0.1.0'
  s.summary          = 'Bluetooth Classic (RFCOMM) for Flutter.'
  s.description      = <<-DESC
Flutter plugin for Bluetooth Classic (RFCOMM) across Android, iOS (MFi), Windows,
macOS, and Linux. On iOS, communication is limited to MFi-certified accessories
via the ExternalAccessory framework.
                       DESC
  s.homepage         = 'https://github.com/almasumdev/flutter_classic_bluetooth'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'almasumdev' => 'dev.almasum@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_classic_bluetooth/Sources/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = ['ExternalAccessory']

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'flutter_classic_bluetooth_privacy' => ['flutter_classic_bluetooth/Sources/flutter_classic_bluetooth/PrivacyInfo.xcprivacy']}
end
