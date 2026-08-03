#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
archive_path="${CONTAINER_GUI_ARCHIVE_PATH:-$project_root/build/Container GUI.xcarchive}"
export_path="${CONTAINER_GUI_EXPORT_PATH:-$project_root/build/export}"
derived_data_path="${CONTAINER_GUI_DERIVED_DATA_PATH:-$project_root/build/DerivedData}"
app_path="$export_path/Container GUI.app"
archive_app_path="$archive_path/Products/Applications/Container GUI.app"
distribution_path="$export_path/Container-GUI.zip"

# Prefer the selected Xcode, but fall back to the beta when only Command Line
# Tools are selected on a development machine.
if ! xcodebuild -version >/dev/null 2>&1; then
    if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    else
        print -u2 "Full Xcode is required. Select it with xcode-select or set DEVELOPER_DIR."
        exit 2
    fi
fi

xcodebuild archive \
    -quiet \
    -project "$project_root/container-gui.xcodeproj" \
    -scheme "Container GUI" \
    -configuration Release \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=

if [[ ! -d "$archive_app_path" ]]; then
    print -u2 "Archived app not found: $archive_app_path"
    exit 1
fi

mkdir -p "$export_path"
rm -rf "$app_path"
rm -f "$distribution_path"
/usr/bin/ditto "$archive_app_path" "$app_path"
/usr/bin/ditto -c -k --keepParent "$app_path" "$distribution_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --verbose=2 "$app_path"

print "Ad-hoc signed app: $app_path"
print "Distribution archive: $distribution_path"
print "Warning: this build is not Developer ID signed or notarized by Apple."
