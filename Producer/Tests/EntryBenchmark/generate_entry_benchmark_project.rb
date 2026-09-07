#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the single mixed-language project used by the offline entry
# benchmark. The local SwiftPM product is referenced relative to this project
# directory, so no CocoaPods integration or network resolution is required.

require 'fileutils'
require 'xcodeproj'

root = File.expand_path(__dir__)
project_path = File.join(root, 'EntryBenchmark.xcodeproj')
generation_marker = File.join(project_path, '.entry-benchmark-generated')
if File.exist?(project_path)
  expected_marker = "EntryBenchmark generated project; safe to replace by generator.\n"
  marker = File.file?(generation_marker) ? File.read(generation_marker) : nil
  unless marker == expected_marker
    abort "refusing to remove existing #{project_path}: missing generator marker"
  end
  FileUtils.rm_rf(project_path)
end

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '1430'
project.root_object.attributes['LastSwiftUpdateCheck'] = '1430'
project.root_object.compatibility_version = 'Xcode 14.0'
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base]

group = project.main_group.new_group('EntryBenchmark', '.')
source_names = %w[
  EntryBenchmarkEntry.m
  EntryBenchmarkMain.m
  EntryBenchmarkMetrics.m
  EntryBenchmarkObjCEntry.m
  EntryBenchmarkOptions.m
  EntryBenchmarkProtocol.m
  EntryBenchmarkRunner.m
  EntryBenchmarkSwiftEntry.swift
]
source_files = source_names.map { |name| group.new_file(name) }
group.new_file('EntryBenchmark-Bridging-Header.h')
group.new_file('EntryBenchmarkEntry.h')
group.new_file('EntryBenchmarkMetrics.h')
group.new_file('EntryBenchmarkObjCEntry.h')
group.new_file('EntryBenchmarkOptions.h')
group.new_file('EntryBenchmarkProtocol.h')
group.new_file('EntryBenchmarkRunner.h')
group.new_file('EntryBenchmark-iOS-Info.plist')

ios_target = project.new_target(:application, 'EntryBenchmark-iOS', :ios)
mac_target = project.new_target(:tool, 'EntryBenchmark-macCLI', :osx)
# Resolve system frameworks against each target's selected SDK, not the SDK
# version bundled with the generator's xcodeproj installation.
project.files.each do |reference|
  next unless reference.path&.end_with?('.framework')

  reference.path = "System/Library/Frameworks/#{File.basename(reference.path)}"
  reference.source_tree = 'SDKROOT'
end
# xcodeproj 1.27 leaves the tool target's product type unset on some Xcode
# versions; set it explicitly so the transferred PIF has a valid target.
mac_target.product_type = 'com.apple.product-type.tool'

[ios_target, mac_target].each do |target|
  target.add_file_references(source_files)
end

local_package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local_package.relative_path = '../../../'
project.root_object.package_references << local_package

[ios_target, mac_target].each do |target|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = local_package
  product.product_name = 'VolcengineTLSProducer'
  target.package_product_dependencies << product

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

def set_common_target_settings(target)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings['SWIFT_VERSION'] = '5.0'
    settings['SWIFT_OBJC_BRIDGING_HEADER'] = '$(SRCROOT)/EntryBenchmark-Bridging-Header.h'
    settings['CLANG_ENABLE_MODULES'] = 'YES'
    settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
    settings['GCC_C_LANGUAGE_STANDARD'] = 'gnu11'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    settings['MACOSX_DEPLOYMENT_TARGET'] = '10.15'
    settings['CODE_SIGNING_ALLOWED'] = 'NO'
    settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings['CURRENT_PROJECT_VERSION'] = '1'
    settings['MARKETING_VERSION'] = '1.0'
    settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  end
end

set_common_target_settings(ios_target)
ios_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['SDKROOT'] = 'iphoneos'
  settings['INFOPLIST_FILE'] = 'EntryBenchmark-iOS-Info.plist'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.volcengine.tls.entry-benchmark'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['SUPPORTS_MACCATALYST'] = 'NO'
end

set_common_target_settings(mac_target)
mac_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['SDKROOT'] = 'macosx'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.volcengine.tls.entry-benchmark.maccli'
  settings['MACH_O_TYPE'] = 'mh_execute'
  settings['CODE_SIGNING_ALLOWED'] = 'NO'
end

project.save

File.write(generation_marker,
           "EntryBenchmark generated project; safe to replace by generator.\n")

# Keep the generated project directly usable by xcodebuild -scheme in CI and
# by the README commands. Schemes are shared project data, not user-local
# state.
[ios_target, mac_target].each do |target|
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(target, nil, launch_target: true)
  scheme.save_as(project_path, target.name, true)
end

puts "generated #{project_path}"
puts 'targets: EntryBenchmark-iOS, EntryBenchmark-macCLI'
puts 'local SwiftPM product: ../../../ (VolcengineTLSProducer)'
