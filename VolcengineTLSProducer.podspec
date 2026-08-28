#
# VolcengineTLSProducer.podspec
#
# VolcengineTLSProducer — Volcengine TLS iOS Producer SDK.
#
# STATUS: release candidate source — the repository tag is still pending.
# iOS 13 legacy-toolchain/device, STS, privacy classification/App Store and
# final soak evidence remain release blockers; this podspec must not be
# published until the exact tag below exists remotely.
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
#   * the C Core is compiled with hidden default visibility and without its
#     standalone VE_TLS_API export annotations; no bare C API is re-exported to
#     consumers. LZ4 is additionally namespaced by lz4_namespace.h.
#   * Consumers see only the single VolcengineTLSProducer module; the Swift
#     public API does not expose bare C types.
#
# The mixed Swift/Objective-C visibility and resource-bundle behavior still
# require `pod lib lint` on a host with CocoaPods; see
# Producer/scripts/verify-consumer-packages.sh.
#

Pod::Spec.new do |s|
  s.name             = 'VolcengineTLSProducer'
  s.version          = '0.0.2'
  s.summary          = 'Volcengine TLS iOS Producer SDK (release candidate source; tag pending).'
  s.description      = <<-DESC
Volcengine TLS (Tinder Log Service) iOS Producer SDK.

Release-candidate source for internal validation. The exact `0.0.2` repository
tag has not been created yet; do not publish this spec from an untagged
checkout. iOS 13 legacy-toolchain/device, STS, privacy/App Store, final soak and
release-owner evidence remain required before Beta or GA claims.
                       DESC
  s.homepage         = 'https://github.com/volcengine/ve-tls-ios-sdk'
  s.license          = { :type => 'Apache License, Version 2.0', :file => 'LICENSE' }
  s.author           = { 'Volcengine TLS Team' => 'tls@volcengine.com' }
  # The source follows the semantic release tag. The 0.0.2 tag is intentionally
  # not fabricated in this checkout; create and push that exact tag only after
  # the release gates pass, then `pod lib lint` against the tagged source.
  s.source           = { :git => 'https://github.com/volcengine/ve-tls-ios-sdk.git',
                         :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.8'
  s.requires_arc          = true

  # Single source tree shared with SwiftPM. Only Producer/Sources is compiled.
  s.source_files = 'Producer/Sources/**/*.{h,m,c,swift}'

  # Explicit excludes (defense in depth):
  #  - Producer/Tests/** is never shipped.
  #  - Fake*/Placeholder sources are structure/test-only and must not ship.
  # The exclusion patterns are defensive and currently match no production
  # Core file; the vendored v0.3.1 Core under Producer/Sources is shipped.
  s.exclude_files = 'Producer/Tests/**',
                    'Producer/Sources/**/Fake*',
                    'Producer/Sources/**/*Fake*',
                    'Producer/Sources/**/*Placeholder*',
                    'Producer/Sources/**/_Placeholder*'

  # Internal symbol hiding: no Bridge/C header is a public header. The
  # VE_TLS_PACKAGE_INTERNAL preprocessor marker is consumed by the vendored
  # export header to select package-internal visibility; OTHER_CFLAGS applies
  # hidden default visibility to C/ObjC compilation. The source-level export
  # branch must be present before publishing this spec.
  # The public surface is Swift-only; keep CocoaPods from warning about an
  # intentionally empty public-header glob.
  s.public_header_files  = []
  s.private_header_files = 'Producer/Sources/CTLSProducerCore/**/*.h',
                           'Producer/Sources/TLSProducerBridge/**/*.h'

  s.compiler_flags = '-DVE_TLS_HAVE_LZ4=1 -DVE_TLS_NO_CURL=1 -DVE_TLS_PACKAGE_INTERNAL=1'

  # Privacy Manifest bundled as a resource bundle.
  s.resource_bundles = {
    'VolcengineTLSProducer' => ['Producer/Sources/VolcengineTLSProducer/Resources/PrivacyInfo.xcprivacy']
  }

  # Modules on; no EXCLUDED_ARCHS hack (per design §12.1).
  s.pod_target_xcconfig = {
    'CLANG_ENABLE_MODULES' => 'YES',
    'DEFINES_MODULE'       => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) VE_TLS_HAVE_LZ4=1 VE_TLS_NO_CURL=1 VE_TLS_PACKAGE_INTERNAL=1',
    'OTHER_CFLAGS'         => '$(inherited) -fvisibility=hidden',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -fvisibility=hidden',
    # RealCoreAdapter.swift uses an implementation-only import of the
    # package-internal Clang module. CocoaPods has one mixed-language target
    # rather than a separate TLSProducerBridge target, so explicitly make this
    # private module map visible to Swift without promoting its headers to the
    # public SDK or recording it as a public Swift module dependency.
    'OTHER_SWIFT_FLAGS'    => '$(inherited) -Xcc -fmodule-map-file=$(PODS_TARGET_SRCROOT)/Producer/scripts/TLSProducerBridge.modulemap',
    'HEADER_SEARCH_PATHS'  => '"$(PODS_TARGET_SRCROOT)/Producer/Sources/CTLSProducerCore/include" "$(PODS_TARGET_SRCROOT)/Producer/Sources/TLSProducerBridge"',
  }

  # Minimal public test specs (ContractTests + ConsumerIntegrationTests).
  s.test_spec 'ContractTests' do |test_spec|
    test_spec.source_files = 'Producer/Tests/ContractTests/**/*.swift'
  end

  s.test_spec 'ConsumerIntegrationTests' do |test_spec|
    # This spec is a public black-box consumer target. The RealCoreAdapter
    # integration file imports the package-internal bridge and directly
    # references private Objective-C classes, so it cannot link against the
    # intentionally hidden symbols in a consumer-facing Pod framework.
    test_spec.source_files = 'Producer/Tests/ConsumerIntegrationTests/ConsumerIntegrationTests.swift',
                             'Producer/Tests/ConsumerIntegrationTests/RealBOEIntegrationTests.swift',
                             'Producer/Tests/ConsumerIntegrationTests/RealHTTPSRedirectIntegrationTests.swift'
  end
end
