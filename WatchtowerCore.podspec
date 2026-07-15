# ─────────────────────────────────────────────────────────────────────────────
# WatchtowerCore — public distribution of the SitePong Watchtower tap-capture
# engine for NATIVE iOS apps (pure Swift / UIKit / SwiftUI — no RN, no npm).
#
# This is a source mirror of the same bridge-free engine that ships inside the
# React-Native `Sitepong` pod. It is published here (public) so native apps can
# consume it without access to the private SitePong monorepo.
#
#   pod 'WatchtowerCore',
#     :git => 'https://github.com/sitepong/watchtower-ios.git',
#     :tag => 'v0.1.0'
# ─────────────────────────────────────────────────────────────────────────────
Pod::Spec.new do |s|
  s.name           = 'WatchtowerCore'
  s.version        = '0.1.1'
  s.summary        = 'Watchtower native iOS tap-capture engine (bridge-free Swift).'
  s.description    = <<-DESC
    Captures taps, screen views, rage/dead taps and redacted screen templates
    for SitePong Watchtower, and uploads them to the tap-analytics ingest API.
    Pure Swift/UIKit/SwiftUI — zero React Native, zero Expo, zero npm.
  DESC
  s.license        = { :type => 'MIT', :file => 'LICENSE' }
  s.author         = 'SitePong'
  s.homepage       = 'https://sitepong.com'
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'

  s.source         = { :git => 'https://github.com/sitepong/watchtower-ios.git',
                       :tag => "v#{s.version}" }

  s.source_files   = 'Sources/WatchtowerCore/**/*.swift'
  s.frameworks     = 'UIKit', 'CoreImage', 'Foundation', 'SwiftUI'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
