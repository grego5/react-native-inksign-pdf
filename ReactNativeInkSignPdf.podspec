require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'ReactNativeInkSignPdf'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = 'https://github.com/grego5/react-native-inksign-pdf'
  s.license      = { :type => 'MIT' }
  s.author       = { 'grego5' => 'maintainers@example.invalid' }
  s.platforms    = { :ios => '15.1' }
  s.source       = { :git => 'https://github.com/grego5/react-native-inksign-pdf.git', :tag => s.version.to_s }
  s.source_files = 'ios/**/*.{h,m,mm,swift}'
  s.exclude_files = 'ios/tests/**/*'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)" "$(PODS_ROOT)/Headers/Private/Yoga"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }
  s.requires_arc = true
  s.libraries    = ['c++']
  s.frameworks   = ['UIKit', 'PencilKit', 'QuartzCore', 'CoreGraphics', 'CoreText', 'PDFKit', 'ImageIO', 'UniformTypeIdentifiers']
  s.dependency 'React-Core'
  s.dependency 'React-Fabric/components/view'
  s.dependency 'NitroModules'

  load 'nitrogen/generated/ios/ReactNativeInkSignPdf+autolinking.rb'
  add_nitrogen_files(s)

  s.test_spec 'LifecycleTests' do |test_spec|
    test_spec.source_files = 'ios/tests/**/*.{swift,mm,h}'
    test_spec.frameworks = ['UIKit', 'PDFKit', 'PencilKit', 'XCTest', 'ImageIO']
  end

end
