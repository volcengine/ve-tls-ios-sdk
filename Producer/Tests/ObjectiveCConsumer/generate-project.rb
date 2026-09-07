#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate a pure Objective-C external consumer project for the public
# VolcengineTLSProducer SwiftPM product.  The generated project intentionally
# keeps both the fixture source and the package reference relative to the
# project directory so a source snapshot can be moved as one unit.

require "fileutils"
require "optparse"
require "pathname"

begin
  require "xcodeproj"
rescue LoadError => error
  warn "xcodeproj gem is required: #{error.message}"
  exit 1
end

PROJECT_NAME = "TLSObjCConsumer"
MACOS_TARGET_NAME = "TLSObjCConsumerMacOS"
IOS_TARGET_NAME = "TLSObjCConsumerIOS"
PACKAGE_PRODUCT_NAME = "VolcengineTLSProducer"
FIXTURE_RELATIVE_PATH = File.join("Producer", "Tests", "ObjectiveCConsumer", "main.m")

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: generate-project.rb --output-directory PATH --repo-root PATH"
  opts.on("--output-directory PATH", "Directory for the generated Xcode project") do |value|
    options[:output_directory] = value
  end
  opts.on("--repo-root PATH", "Root of the local Swift package snapshot") do |value|
    options[:repo_root] = value
  end
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end
end

begin
  parser.parse!(ARGV)
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
end

unless ARGV.empty?
  warn "unexpected arguments: #{ARGV.join(" ")}"
  warn parser
  exit 2
end

missing_options = %i[output_directory repo_root].reject { |key| options.key?(key) }
unless missing_options.empty?
  warn "missing required option(s): #{missing_options.map { |key| "--#{key.to_s.tr("_", "-")}" }.join(", ")}"
  warn parser
  exit 2
end

output_directory = File.expand_path(options[:output_directory])
repo_root = File.expand_path(options[:repo_root])
source_path = File.join(repo_root, FIXTURE_RELATIVE_PATH)
project_path = File.join(output_directory, "#{PROJECT_NAME}.xcodeproj")

unless File.file?(File.join(repo_root, "Package.swift"))
  warn "repo-root does not contain Package.swift: #{repo_root}"
  exit 1
end

unless File.file?(source_path)
  warn "Objective-C fixture is missing: #{source_path}"
  exit 1
end

if output_directory == repo_root
  warn "output-directory must be separate from repo-root"
  exit 1
end

FileUtils.mkdir_p(output_directory)

# Reuse the requested output directory while refusing to replace any existing
# project. This keeps generation non-destructive and makes each output path an
# explicitly controlled artifact location.
if File.exist?(project_path)
  warn "refusing to replace existing path: #{project_path}"
  exit 1
end

def relative_path(path, base_directory)
  Pathname.new(path).relative_path_from(Pathname.new(base_directory)).to_s
end

def set_common_build_settings(target, platform, deployment_target)
  is_ios = platform == :ios
  runpath = if is_ios
              ["/usr/lib/swift", "$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]
            else
              ["/usr/lib/swift", "$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"]
            end

  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["PRODUCT_NAME"] = target.name
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = if is_ios
                                               "com.volcengine.tls.objc.consumer.ios"
                                             else
                                               "com.volcengine.tls.objc.consumer.macos"
                                             end
    settings["CLANG_ENABLE_MODULES"] = "YES"
    settings["CLANG_ENABLE_OBJC_ARC"] = "YES"
    settings["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"] = "YES"
    settings["CODE_SIGNING_ALLOWED"] = "NO"
    settings["CODE_SIGNING_REQUIRED"] = "NO"
    settings["CODE_SIGN_IDENTITY"] = ""
    settings["LD_RUNPATH_SEARCH_PATHS"] = runpath
    settings["ONLY_ACTIVE_ARCH"] = "YES"
    settings["CURRENT_PROJECT_VERSION"] = "1"
    settings["MARKETING_VERSION"] = "1.0"

    if is_ios
      settings["SDKROOT"] = "iphoneos"
      settings["IPHONEOS_DEPLOYMENT_TARGET"] = deployment_target
      settings["TARGETED_DEVICE_FAMILY"] = "1,2"
      settings["GENERATE_INFOPLIST_FILE"] = "YES"
      settings["INFOPLIST_KEY_CFBundleDisplayName"] = "$(PRODUCT_NAME)"
      settings["INFOPLIST_KEY_LSRequiresIPhoneOS"] = "YES"
      settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
    else
      settings["SDKROOT"] = "macosx"
      settings["MACOSX_DEPLOYMENT_TARGET"] = deployment_target
      settings["GENERATE_INFOPLIST_FILE"] = "YES"
    end
  end
end

def add_swift_package_product(project, target, package_reference)
  product_dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dependency.package = package_reference
  product_dependency.product_name = PACKAGE_PRODUCT_NAME
  target.package_product_dependencies << product_dependency

  # A package product is represented in the target's Frameworks phase by a
  # PBXBuildFile whose product_ref points at the Swift package dependency.
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dependency
  target.frameworks_build_phase.files << build_file
end

def normalize_system_framework_paths(target)
  target.frameworks_build_phase.files.each do |build_file|
    file_reference = build_file.file_ref
    next unless file_reference
    next unless file_reference.respond_to?(:path) && file_reference.path
    next unless file_reference.path.end_with?(".framework")

    framework_name = file_reference.name || File.basename(file_reference.path)
    file_reference.path = File.join("System", "Library", "Frameworks", framework_name)
    file_reference.source_tree = "SDKROOT"
  end
end

# Xcode 14.0+ project format is understood by the Intel Xcode 14.3.1
# validation host and supports local Swift package references.
project = Xcodeproj::Project.new(project_path, false, 56)
project.root_object.attributes["LastUpgradeCheck"] = "1430"
project.root_object.attributes["LastSwiftUpdateCheck"] = "1430"
project.root_object.development_region = "en"
project.root_object.known_regions = ["en", "Base"]

project_directory = output_directory
source_reference = project.main_group.new_file(relative_path(source_path, project_directory))
source_reference.last_known_file_type = "sourcecode.c.objc"

package_reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_reference.relative_path = relative_path(repo_root, project_directory)
project.root_object.package_references << package_reference

macos_target = project.new_target(
  :command_line_tool,
  MACOS_TARGET_NAME,
  :osx,
  "10.15",
  nil,
  :objc
)
ios_target = project.new_target(
  :application,
  IOS_TARGET_NAME,
  :ios,
  "13.0",
  nil,
  :objc
)

[macos_target, ios_target].each do |target|
  target.add_file_references([source_reference])
  add_swift_package_product(project, target, package_reference)
end

# new_target adds the platform's default Foundation/Cocoa framework. UIKit is
# intentionally added only to the iOS application target.
ios_target.add_system_framework("UIKit")
[macos_target, ios_target].each { |target| normalize_system_framework_paths(target) }

set_common_build_settings(macos_target, :osx, "10.15")
set_common_build_settings(ios_target, :ios, "13.0")

project.save
[macos_target, ios_target].each do |target|
  scheme = Xcodeproj::XCScheme.new
  scheme.configure_with_targets(
    target,
    nil,
    launch_target: target.launchable_target_type?
  )
  scheme.save_as(project_path, target.name, true)
end

puts "generated_project=#{project_path}"
puts "macos_target=#{MACOS_TARGET_NAME}"
puts "ios_target=#{IOS_TARGET_NAME}"
puts "relative_source=#{relative_path(source_path, project_directory)}"
puts "relative_package=#{package_reference.relative_path}"
