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

  # Backend selection: wgpu-native (default, vendored by
  # scripts/fetch_wgpu_native.sh) or Dawn (staged by
  # scripts/stage_dawn_macos.sh):
  #   NITRO_WEBGPU_BACKEND=dawn flutter run -d macos
  header_paths = '$(inherited) "${PODS_ROOT}/../Flutter/ephemeral/.symlinks/plugins/nitro/src/native" "${PODS_TARGET_SRCROOT}/../src" "${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"'
  backend_defines = '$(inherited)'
  ldflags = '$(inherited)'
  if ENV['NITRO_WEBGPU_BACKEND'] == 'dawn'
    s.vendored_frameworks = 'nitro_webgpu/Frameworks/webgpu_dawn.xcframework'
    backend_defines += ' NITRO_WEBGPU_BACKEND_DAWN=1 NITRO_WEBGPU_HAS_GLSLANG=1'
    brew_prefix = File.directory?('/opt/homebrew/include') ? '/opt/homebrew' : '/usr/local'
    header_paths += ' "${PODS_TARGET_SRCROOT}/../src/third_party/dawn/include"' \
                    " \"#{brew_prefix}/include\""
    ldflags += " -L#{brew_prefix}/lib -lglslang -lglslang-default-resource-limits"
  else
    s.vendored_frameworks = 'nitro_webgpu/Frameworks/wgpu_native.xcframework'
  end
  s.frameworks = 'Metal', 'QuartzCore'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_PREPROCESSOR_DEFINITIONS' => backend_defines,
    'HEADER_SEARCH_PATHS' => header_paths,
    'OTHER_LDFLAGS' => ldflags
  }
  s.swift_version = '5.9'
end
