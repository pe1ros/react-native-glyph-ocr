require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# iOS side of the OCR spike: Apple Vision text recognition (ios/). PaddleOCR and ML Kit are Android only.
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

  load 'nitrogen/generated/ios/NitroPurelyOcr+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  install_modules_dependencies(s)
end
