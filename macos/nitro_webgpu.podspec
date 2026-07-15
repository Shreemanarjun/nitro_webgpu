#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint nitro_webgpu.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'nitro_webgpu'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'nitro_webgpu_privacy' => ['nitro_webgpu/Sources/nitro_webgpu/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.dependency 'nitro'

  # wgpu-native static lib (vendored by scripts/fetch_wgpu_native.sh).
  s.vendored_frameworks = 'nitro_webgpu/Frameworks/wgpu_native.xcframework'
  s.frameworks = 'Metal', 'QuartzCore'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/../Flutter/ephemeral/.symlinks/plugins/nitro/src/native" "${PODS_TARGET_SRCROOT}/../src" "${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"'
  }
  s.swift_version = '5.9'
end
