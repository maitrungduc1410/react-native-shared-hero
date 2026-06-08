require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "SharedHero"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/maitrungduc1410/react-native-shared-hero.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift,cpp}"

  # `SharedHeroView.h` imports `<React/RCTViewComponentView.h>` which
  # transitively pulls in C++-only React-Fabric headers (e.g. EventBeat.h
  # `#include <atomic>`). Swift module compilation parses public headers as
  # Obj-C and chokes on the C++. Marking the Obj-C++ headers private keeps
  # them out of the auto-generated umbrella but still importable from the
  # `.mm` shim via `#import "SharedHeroView.h"`.
  s.private_header_files = "ios/SharedHeroView.h"

  s.swift_versions = ["5.0"]

  # Bridging headers are unsupported on framework targets (use_frameworks!),
  # so we don't ship one. All Obj-C → Swift bridging happens via @objc-exported
  # Swift APIs picked up through the auto-generated `SharedHero-Swift.h`,
  # which our `.mm` shim imports directly.
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++20",
  }

  install_modules_dependencies(s)
end
