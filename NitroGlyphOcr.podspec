require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Apple Vision on iOS (ios/). Build flags, read from ENV when `pod install` runs:
#   GlyphOcr_paddleOnIos=1  also PaddleOCR on ONNX Runtime (ios/paddle), for languages Vision does
#                           not read; adds onnxruntime-objc to the app
paddle_on_ios = ["1", "true"].include?(ENV["GlyphOcr_paddleOnIos"].to_s)

Pod::Spec.new do |s|
  s.name         = "NitroGlyphOcr"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = "MIT"
  s.authors      = package["author"]

  # VNRecognizeTextRequest revision 3 (Russian, Ukrainian, the current accuracy) needs iOS 16.
  s.platforms    = { :ios => "16.0" }
  s.source       = { :git => "https://github.com/pe1ros/react-native-glyph-ocr.git", :tag => "v#{s.version}" }

  s.source_files = [
    # Implementation (Swift)
    "ios/**/*.{swift}",
  ]
  # models/: the model manifest and the recognizer dictionaries (a few KB), read by ModelStore.swift.
  s.resource_bundles = { "NitroGlyphOcr" => ["models"] }
  s.frameworks = "Vision", "Photos", "CoreImage", "CoreVideo"

  # Optimized in Debug builds too: the frame meter loops over pixels on every camera frame
  # (60 ms per frame at -Onone, about 1 ms at -O).
  xcconfig = { "SWIFT_OPTIMIZATION_LEVEL" => "-O" }
  if paddle_on_ios
    s.dependency "onnxruntime-objc", "1.30.0"
    xcconfig["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) GLYPHOCR_PADDLE"
  end
  s.pod_target_xcconfig = xcconfig

  load 'nitrogen/generated/ios/NitroGlyphOcr+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  install_modules_dependencies(s)
end
