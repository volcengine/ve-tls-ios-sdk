#
# VolcengineTLSProducer.podspec
#
# VolcengineTLSProducer — Volcengine TLS iOS Producer SDK.
#
# STATUS: Development Preview — not a Beta release. The C Core release gate is
# not met (see Producer/CORE_VERSION); no persistent/retry/ACK/real-send claims.
# Compilation and test evidence is pending a macOS + Xcode toolchain.
#
# CocoaPods and SwiftPM compile the SAME Producer/Sources tree (no dual
# implementation). This podspec only ever pulls from Producer/Sources; the
# legacy VeTLSiOSSDK targets are never compiled into this Pod.
#
# Internal symbol hiding strategy
# --------------------------------
# CocoaPods compiles the C Core, the Objective-C bridge and the Swift public
# API into a single pod target. To keep consumers on the Swift API only:
#
#   * C Core headers (Producer/Sources/CTLSProducerCore) and Bridge headers
#     (Producer/Sources/TLSProducerBridge) are NOT declared as
#     public_header_files. They compile as private/project headers.
#   * C symbols are namespaced with the Core's ve_tls_iosp_* prefix mechanism
#     and are statically linked; no bare C API is re-exported to consumers.
#   * Consumers see only the single VolcengineTLSProducer module; the Swift
#     public API does not expose bare C types.
#
# KNOWN CAVEAT (must be validated on macOS with `pod lib lint`): in a single
# mixed Swift/Objective-C CocoaPods target, Swift can only reach Objective-C
# headers that are part of the module's generated umbrella header. With Bridge
# headers kept private, the Swift layer may not see the Bridge interface. If
# lint fails on this, the fallback is a custom module_map (private submodule)
# or promoting the minimal Bridge umbrella header
# (Producer/Sources/TLSProducerBridge/include/TLSProducerBridge.h) to
# public_header_files. This will be resolved in the macOS validation pass;
# see Producer/scripts/verify-consumer-packages.sh.
#

Pod::Spec.new do |s|
  s.name             = 'VolcengineTLSProducer'
  s.version          = '0.0.1'
  s.summary          = 'Volcengine TLS iOS Producer SDK (Development Preview — not a Beta release).'
  s.description      = <<-DESC
Volcengine TLS (Tinder Log Service) iOS Producer SDK.

Development Preview — not a Beta release. The C Core release gate is not met;
persistent/retry/ACK/real-send behavior is not claimed. Compilation and test
evidence is pending a macOS + Xcode toolchain.
                       DESC
  s.homepage         = 'https://github.com/volcengine/ve-tls-ios-sdk'
  s.license          = { :type => 'Apache License, Version 2.0', :file => 'LICENSE' }
  s.author           = { 'Volcengine TLS Team' => 'tls@volcengine.com' }
  # TODO(pre-publish): this pin points at the master baseline (64ae030),
  # which does not contain the Producer/ tree. Before publishing the pod,
  # update it to the producer-branch tip commit (or switch to :tag).
  s.source           = { :git => 'https://github.com/volcengine/ve-tls-ios-sdk.git',
                         :commit => '64ae0302c613c5bd111cfe06d5a7652f974bf133' }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.8'
  s.requires_arc          = true

  # Single source tree shared with SwiftPM. Only Producer/Sources is compiled.
  s.source_files = 'Producer/Sources/**/*.{h,m,c,swift}'

  # Explicit excludes (defense in depth):
  #  - Producer/Tests/** is never shipped (ProducerTestSupport lives there).
  #  - Fake*/Placeholder sources are structure/test-only and must not ship.
  # NOTE: the only placeholder currently excluded from the Pod's source set
  # is CTLSProducerCorePlaceholder.c; no shipped source references
  # ve_tls_iosp_core_version, so the Pod has no link gap. The real C Core
  # (Wave 3) replaces the placeholder target entirely.
  s.exclude_files = 'Producer/Tests/**',
                    'Producer/Sources/**/Fake*',
                    'Producer/Sources/**/*Fake*',
                    'Producer/Sources/**/*Placeholder*',
                    'Producer/Sources/**/_Placeholder*'

  # Internal symbol hiding: no Bridge/C header is a public header.
  # (See the strategy comment at the top of this file.)
  s.public_header_files  = 'Producer/Sources/VolcengineTLSProducer/**/*.h'
  s.private_header_files = 'Producer/Sources/CTLSProducerCore/**/*.h',
                           'Producer/Sources/TLSProducerBridge/**/*.h'

  # Privacy Manifest bundled as a resource bundle.
  s.resource_bundles = {
    'VolcengineTLSProducer' => ['Producer/Sources/VolcengineTLSProducer/Resources/PrivacyInfo.xcprivacy']
  }

  # Modules on; no EXCLUDED_ARCHS hack (per design §12.1).
  s.pod_target_xcconfig = {
    'CLANG_ENABLE_MODULES' => 'YES',
    'DEFINES_MODULE'       => 'YES',
    'HEADER_SEARCH_PATHS'  => '"$(PODS_TARGET_SRCROOT)/Producer/Sources/CTLSProducerCore/include" "$(PODS_TARGET_SRCROOT)/Producer/Sources/TLSProducerBridge"',
  }

  # Minimal test specs (ContractTests + ConsumerIntegrationTests).
  # ProducerTestSupport sources are compiled directly into the test bundles
  # (it is a test-only support target, not shipped).
  s.test_spec 'ContractTests' do |test_spec|
    test_spec.source_files = 'Producer/Tests/ContractTests/**/*.swift',
                             'Producer/Tests/ProducerTestSupport/**/*.swift'
  end

  s.test_spec 'ConsumerIntegrationTests' do |test_spec|
    test_spec.source_files = 'Producer/Tests/ConsumerIntegrationTests/**/*.swift'
  end
end
