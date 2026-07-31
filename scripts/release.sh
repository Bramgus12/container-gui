#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
archive_path="${CONTAINER_GUI_ARCHIVE_PATH:-$project_root/build/Container GUI.xcarchive}"
export_path="${CONTAINER_GUI_EXPORT_PATH:-$project_root/build/export}"
identity="${DEVELOPER_ID_APPLICATION:-}"
notary_profile="${NOTARYTOOL_PROFILE:-}"

if [[ -z "$identity" || -z "$notary_profile" ]]; then
    print -u2 "Set DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE before releasing."
    exit 2
fi

xcodebuild archive \
    -project "$project_root/container-gui.xcodeproj" \
    -scheme "Container GUI" \
    -configuration Release \
    -archivePath "$archive_path" \
    CODE_SIGN_IDENTITY="$identity"

xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$project_root/config/DeveloperIDExportOptions.plist"

app_path="$export_path/Container GUI.app"
submission_path="$export_path/Container-GUI-notarization.zip"

/usr/bin/ditto -c -k --keepParent "$app_path" "$submission_path"
xcrun notarytool submit "$submission_path" \
    --keychain-profile "$notary_profile" \
    --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

print "Signed, notarized, and stapled app: $app_path"
