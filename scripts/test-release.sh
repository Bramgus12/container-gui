#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
derived_data_path="${CONTAINER_GUI_RELEASE_TEST_DERIVED_DATA_PATH:-$project_root/build/ReleaseTestDerivedData}"

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

# Release archives retain Hardened Runtime. An ad-hoc-signed test host has no
# Team ID, however, so macOS library validation rejects its separately signed
# XCTest bundles. Disable Hardened Runtime only for this test build and enable
# @testable imports; neither override changes the archive configuration.
xcodebuild test \
    -project "$project_root/container-gui.xcodeproj" \
    -scheme "Container GUI" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$derived_data_path" \
    "$@" \
    ENABLE_TESTABILITY=YES \
    ENABLE_HARDENED_RUNTIME=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM=
