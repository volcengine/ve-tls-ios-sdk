#!/usr/bin/env ruby

require 'xcodeproj'

root = File.expand_path(__dir__)
project_path = File.join(root, 'PerformanceHarness.xcodeproj')
abort("refusing to overwrite #{project_path}") if File.exist?(project_path)

project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, 'PerformanceHarness', :ios, '13.0')
sources_group = project.main_group.new_group('Sources', 'Sources')

source_names = [
  'AppDelegate.swift',
  'SLSBenchmarkClient.m',
]
source_references = source_names.map { |name| sources_group.new_file(name) }
target.add_file_references(source_references)

[
  'SLSBenchmarkClient.h',
  'PerformanceHarness-Bridging-Header.h',
  'Info.plist',
].each { |name| sources_group.new_file(name) }

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.volcengine.tls.PerformanceHarness'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['INFOPLIST_FILE'] = 'Sources/Info.plist'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Sources/PerformanceHarness-Bridging-Header.h'
  settings['SWIFT_VERSION'] = '5.8'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['CODE_SIGNING_ALLOWED'] = 'NO'
  settings['CODE_SIGNING_REQUIRED'] = 'NO'
  settings['EXCLUDED_ARCHS'] = ''
end

project.recreate_user_schemes
project.save
