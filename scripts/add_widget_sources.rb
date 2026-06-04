#!/usr/bin/env ruby
# Ensures every BoleraWidgets/*.swift source is a member of both widget
# extension targets' Sources build phase (and registered in the project group).
# Idempotent — safe to re-run after adding new widget source files.

require 'xcodeproj'

PROJECT_PATH = File.expand_path(File.join(__dir__, '..', 'Bolera.xcodeproj'))
WIDGET_DIR   = File.expand_path(File.join(__dir__, '..', 'BoleraWidgets'))
TARGET_NAMES = %w[BoleraWidgets BoleraWidgetsMac]

project = Xcodeproj::Project.open(PROJECT_PATH)
group = project.main_group['BoleraWidgets']
raise 'BoleraWidgets group not found — run add_widget_target.rb first' unless group

swift_files = Dir.children(WIDGET_DIR).select { |f| f.end_with?('.swift') }.sort

refs = {}
swift_files.each do |name|
  refs[name] = group.files.find { |f| f.display_name == name } || group.new_reference(name)
end

TARGET_NAMES.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  next unless target
  swift_files.each { |name| target.source_build_phase.add_file_reference(refs[name], true) }
end

project.save
puts "Ensured #{swift_files.size} sources (#{swift_files.join(', ')}) in: #{TARGET_NAMES.join(', ')}"
