# Volcengine TLS Producer SDK for iOS and macOS.

Pod::Spec.new do |s|
  s.name             = 'VolcengineTLSProducer'
  s.version          = '2.0.1'
  s.summary          = 'Volcengine TLS Producer SDK for iOS and macOS.'
  s.description      = <<-DESC
Volcengine TLS Producer SDK for iOS and macOS.
Provides asynchronous batching, compression, retry, and optional persistent
delivery for Apple applications.
                       DESC
  s.homepage         = 'https://github.com/volcengine/ve-tls-ios-sdk'
  s.license          = { :type => 'Apache License, Version 2.0', :file => 'LICENSE' }
  s.author           = { 'Volcengine TLS Team' => 'tls@volcengine.com' }
  # Producer releases use v2.0.x; v1.x remains the legacy SDK line.
  s.source           = { :git => 'https://github.com/volcengine/ve-tls-ios-sdk.git',
                         :tag => "v#{s.version}" }

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.swift_version         = '5.8'
  s.requires_arc          = true

  # SwiftPM and CocoaPods compile the same source tree.
  s.source_files = 'Producer/Sources/**/*.{h,m,c,swift}'

  # Keep the private module map when CocoaPods cleans downloaded sources.
  s.preserve_paths = 'Producer/scripts/TLSProducerBridge.modulemap'

  # Tests and test doubles are not shipped.
  s.exclude_files = 'Producer/Tests/**',
                    'Producer/Sources/**/Fake*',
                    'Producer/Sources/**/*Fake*',
                    'Producer/Sources/**/*Placeholder*',
                    'Producer/Sources/**/_Placeholder*'

  # Public Objective-C APIs are exported through the generated Swift header.
  # C Core and bridge headers remain private.
  s.public_header_files  = []
  s.private_header_files = 'Producer/Sources/CTLSProducerCore/**/*.h',
                           'Producer/Sources/TLSProducerBridge/**/*.h'

  s.compiler_flags = '-DVE_TLS_HAVE_LZ4=1 -DVE_TLS_NO_CURL=1 -DVE_TLS_PACKAGE_INTERNAL=1'

  s.resource_bundles = {
    'VolcengineTLSProducer' => ['Producer/Sources/VolcengineTLSProducer/Resources/PrivacyInfo.xcprivacy']
  }

  s.pod_target_xcconfig = {
    'CLANG_ENABLE_MODULES' => 'YES',
    'DEFINES_MODULE'       => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) VE_TLS_HAVE_LZ4=1 VE_TLS_NO_CURL=1 VE_TLS_PACKAGE_INTERNAL=1',
    'OTHER_CFLAGS'         => '$(inherited) -fvisibility=hidden',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -fvisibility=hidden',
    # Keep the Clang argument intact when the checkout or Pods path has spaces.
    'OTHER_SWIFT_FLAGS'    => '$(inherited) -Xcc "-fmodule-map-file=$(PODS_TARGET_SRCROOT)/Producer/scripts/TLSProducerBridge.modulemap"',
    'HEADER_SEARCH_PATHS'  => '"$(PODS_TARGET_SRCROOT)/Producer/Sources/CTLSProducerCore/include" "$(PODS_TARGET_SRCROOT)/Producer/Sources/TLSProducerBridge"',
  }

  s.test_spec 'ContractTests' do |test_spec|
    test_spec.source_files = 'Producer/Tests/ContractTests/**/*.swift'
  end

  s.test_spec 'ConsumerIntegrationTests' do |test_spec|
    test_spec.source_files = 'Producer/Tests/ConsumerIntegrationTests/ConsumerIntegrationTests.swift',
                             'Producer/Tests/ConsumerIntegrationTests/RealHTTPSRedirectIntegrationTests.swift'
  end
end
