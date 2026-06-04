#!/usr/bin/env ruby
# Adds the BoleraWidgets WidgetKit app-extension target to Bolera.xcodeproj,
# links the local BoleraCore Swift package into it, and embeds it in the Bolera
# (iOS) host app. Idempotent: re-running is a no-op once the target exists.
#
# Usage: ruby scripts/add_widget_target.rb [--mac]
#   (default) iOS target BoleraWidgets embedded in Bolera
#   --mac     macOS target BoleraWidgetsMac embedded in Bolera-mac (Phase 2)

require 'xcodeproj'

PROJECT_PATH = File.expand_path(File.join(__dir__, '..', 'Bolera.xcodeproj'))
TEAM = 'J4UJD4Z33J'
MAC = ARGV.include?('--mac')

if MAC
  TARGET_NAME   = 'BoleraWidgetsMac'
  HOST_NAME     = 'Bolera-mac'
  BUNDLE_ID     = 'com.giantmushroom.bolera.BoleraWidgetsMac'
  ENTITLEMENTS  = 'BoleraWidgets/BoleraWidgetsMac.entitlements'
  PLATFORM      = :osx
  DEPLOYMENT    = '14.0'
  SDKROOT       = 'macosx'
  RPATHS        = ['$(inherited)', '@executable_path/../Frameworks',
                   '@executable_path/../../../../Frameworks']
else
  TARGET_NAME   = 'BoleraWidgets'
  HOST_NAME     = 'Bolera'
  BUNDLE_ID     = 'com.giantmushroom.bolera.BoleraWidgets'
  ENTITLEMENTS  = 'BoleraWidgets/BoleraWidgets.entitlements'
  PLATFORM      = :ios
  DEPLOYMENT    = '18.0'
  SDKROOT       = 'iphoneos'
  RPATHS        = ['$(inherited)', '@executable_path/Frameworks',
                   '@executable_path/../../Frameworks']
end

SWIFT_FILES = %w[BoleraWidgetsBundle.swift NowPlayingWidget.swift NowPlayingWidgetViews.swift]

project = Xcodeproj::Project.open(PROJECT_PATH)

# Normalize the existing iOS widget target's CFBundleVersion to its host (23);
# the shared Info.plist now reads $(CURRENT_PROJECT_VERSION).
if (ios_t = project.targets.find { |t| t.name == 'BoleraWidgets' })
  ios_t.build_configurations.each { |c| c.build_settings['CURRENT_PROJECT_VERSION'] = '23' }
  project.save
end

if project.targets.any? { |t| t.name == TARGET_NAME }
  puts "Target #{TARGET_NAME} already exists — nothing to do."
  exit 0
end

# Locate the existing local BoleraCore package reference (do NOT duplicate it).
pkg_ref = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    r.display_name.to_s.include?('BoleraCore')
end
raise 'Could not find the local BoleraCore Swift package reference' unless pkg_ref

host = project.targets.find { |t| t.name == HOST_NAME }
raise "Could not find host target #{HOST_NAME}" unless host

# --- File group + references (shared 'BoleraWidgets' folder at repo root) ---
group = project.main_group['BoleraWidgets'] || project.main_group.new_group('BoleraWidgets', 'BoleraWidgets')
refs = {}
(SWIFT_FILES + ['Info.plist', 'BoleraWidgets.entitlements', 'BoleraWidgetsMac.entitlements']).each do |name|
  next if name == 'BoleraWidgetsMac.entitlements' && !MAC
  existing = group.files.find { |f| f.display_name == name }
  refs[name] = existing || group.new_reference(name)
end

# --- The extension target ---
target = project.new_target(:app_extension, TARGET_NAME, PLATFORM, DEPLOYMENT)

# Compile the (shared) Swift sources.
SWIFT_FILES.each { |name| target.source_build_phase.add_file_reference(refs[name], true) }

# Build settings on both Debug and Release.
target.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER']      = BUNDLE_ID
  bs['PRODUCT_NAME']                   = '$(TARGET_NAME)'
  bs['DEVELOPMENT_TEAM']               = TEAM
  bs['CODE_SIGN_STYLE']                = 'Automatic'
  bs['CODE_SIGN_ENTITLEMENTS']         = ENTITLEMENTS
  bs['INFOPLIST_FILE']                 = 'BoleraWidgets/Info.plist'
  bs['GENERATE_INFOPLIST_FILE']        = 'NO'
  bs['INFOPLIST_KEY_CFBundleDisplayName'] = 'Bolera'
  bs['SDKROOT']                        = SDKROOT
  bs['SKIP_INSTALL']                   = 'YES'
  bs['SWIFT_VERSION']                  = '5.0'
  bs['SWIFT_EMIT_LOC_STRINGS']         = 'YES'
  bs['MARKETING_VERSION']              = '1.0.0'
  # CFBundleVersion of an embedded extension must match its host app.
  bs['CURRENT_PROJECT_VERSION']        = MAC ? '20' : '23'
  bs['LD_RUNPATH_SEARCH_PATHS']        = RPATHS
  if MAC
    bs['MACOSX_DEPLOYMENT_TARGET']     = DEPLOYMENT
  else
    bs['IPHONEOS_DEPLOYMENT_TARGET']   = DEPLOYMENT
    bs['TARGETED_DEVICE_FAMILY']       = '1,2'
  end
end

# --- Link the BoleraCore package product into the extension ---
dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.product_name = 'BoleraCore'
dep.package = pkg_ref
target.package_product_dependencies << dep

build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = dep
target.frameworks_build_phase.files << build_file

# --- Embed the extension into the host app ---
host.add_dependency(target)
embed = host.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
embed_file = embed.add_file_reference(target.product_reference)
embed_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "Added target #{TARGET_NAME}, linked BoleraCore, embedded in #{HOST_NAME}."
