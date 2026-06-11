#!/bin/sh
# Xcode Cloud pre-build: stamp a unique, monotonically-increasing build number
# derived from the CI build counter, kept above the highest manually-uploaded
# build (33) so TestFlight never rejects a duplicate CFBundleVersion.
set -e
NEW=$(( 40 + ${CI_BUILD_NUMBER:-1} ))
REPO="$CI_PRIMARY_REPOSITORY_PATH"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW" "$REPO/Bolera/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW" "$REPO/Bolera-mac/Info.plist"
# Widgets read CURRENT_PROJECT_VERSION from the project; set every target to NEW
# (app targets read Info.plist, so changing their stale CPV is harmless).
/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEW;/g" "$REPO/Bolera.xcodeproj/project.pbxproj"

echo "ci_pre_xcodebuild: set CFBundleVersion = $NEW (CI build $CI_BUILD_NUMBER)"
