require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Apple Vision on iOS (ios/). Build flags (docs/ocr-library-api.md, section 2), read from ENV in the Podfile:
#   PurelyOcr_paddleOnIos=1  PaddleOCR on ONNX Runtime on iOS: planned, not implemented yet
if ENV["PurelyOcr_paddleOnIos"] == "1" || ENV["PurelyOcr_paddleOnIos"] == "true"
  raise "[PurelyOcr] PurelyOcr_paddleOnIos is not implemented yet: iOS has Apple Vision only"
end

Pod::Spec.new do |s|
  s.name         = "NitroPurelyOcr"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/pe1ros/purely-mobile"
  s.license      = "UNLICENSED"
  s.authors      = "Purely"

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/pe1ros/purely-mobile.git", :tag => "#{s.version}" }

  s.source_files = [
    # Implementation (Swift)
    "ios/**/*.{swift}",
  ]
  # models/: the model manifest and the recognizer dictionaries (a few KB), read by ModelStore.swift.
  s.resource_bundles = { "NitroPurelyOcr" => ["models"] }
  s.frameworks = "Vision", "Photos", "CoreImage", "CoreVideo"

  # Optimized in Debug builds too: the frame meter loops over pixels on every camera frame
  # (60 ms per frame at -Onone, about 1 ms at -O).
  s.pod_target_xcconfig = { "SWIFT_OPTIMIZATION_LEVEL" => "-O" }

  load 'nitrogen/generated/ios/NitroPurelyOcr+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  install_modules_dependencies(s)
end
