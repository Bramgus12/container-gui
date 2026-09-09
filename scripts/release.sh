#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
archive_path="${CARGODECK_ARCHIVE_PATH:-$project_root/build/CargoDeck.xcarchive}"
export_path="${CARGODECK_EXPORT_PATH:-$project_root/build/export}"
derived_data_path="${CARGODECK_DERIVED_DATA_PATH:-$project_root/build/DerivedData}"
export_options_template="${CARGODECK_EXPORT_OPTIONS:-$project_root/config/DeveloperIDExportOptions.plist}"
export_options_path="$project_root/build/ExportOptions.plist"
app_path="$export_path/CargoDeck.app"
dmg_staging_path="$project_root/build/dmg-staging"
notarization_zip_path="$project_root/build/CargoDeck-notarize.zip"
distribution_path="$export_path/CargoDeck.dmg"
legacy_distribution_path="$export_path/CargoDeck.zip"
legacy_checksum_path="$export_path/SHA256SUMS.txt"
notary_profile="${CARGODECK_NOTARY_PROFILE:-cargodeck-notary}"
skip_notarization="${CARGODECK_SKIP_NOTARIZATION:-0}"

usage() {
    cat <<'USAGE'
Usage: scripts/release.sh [--skip-notarization]

Archives CargoDeck with the Developer ID Application certificate, exports a
hardened-runtime app, submits it to Apple's notary service, staples the ticket,
and packages a signed, notarized, stapled CargoDeck.dmg.

Options:
  --skip-notarization   Sign with Developer ID but do not contact Apple. The
                        resulting DMG is NOT distributable. Local dry runs only.
  -h, --help            Show this help.

Environment overrides:
  CARGODECK_SIGNING_IDENTITY  Developer ID Application identity to use.
                                  Defaults to the only matching keychain identity.
  CARGODECK_TEAM_ID           Team ID. Defaults to the project's DEVELOPMENT_TEAM.
  CARGODECK_EXPORT_OPTIONS    Export options plist template.

Notary credentials, in the order they are tried:
  CARGODECK_NOTARY_KEY, CARGODECK_NOTARY_KEY_ID, CARGODECK_NOTARY_ISSUER
      App Store Connect API key file, key ID, and issuer UUID.
  CARGODECK_APPLE_ID, CARGODECK_APP_PASSWORD
      Apple ID and an app-specific password.
  CARGODECK_NOTARY_PROFILE    notarytool keychain profile name.
                                  Defaults to cargodeck-notary.
USAGE
}

fail() {
    print -u2 "Error: $1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --skip-notarization) skip_notarization=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "Unknown argument: $1" ;;
    esac
    shift
done

# Prefer the selected Xcode, but fall back to the beta when only Command Line
# Tools are selected on a development machine.
if ! xcodebuild -version >/dev/null 2>&1; then
    if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    else
        fail "Full Xcode is required. Select it with xcode-select or set DEVELOPER_DIR."
    fi
fi

# Resolve the Developer ID Application certificate. Distribution outside the App
# Store requires this certificate; an Apple Development certificate cannot be
# notarized.
signing_identity="${CARGODECK_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    typeset -a developer_id_identities
    developer_id_identities=(${(f)"$(/usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')"})
    developer_id_identities=(${developer_id_identities:#})

    if (( ${#developer_id_identities} == 0 )); then
        print -u2 "Error: no \"Developer ID Application\" certificate is available in the keychain."
        print -u2 ""
        print -u2 "Create one in Xcode > Settings > Accounts > your Apple ID > Manage Certificates,"
        print -u2 "then click + and choose \"Developer ID Application\". You can also request it at"
        print -u2 "https://developer.apple.com/account/resources/certificates and double-click the"
        print -u2 "download to install it. Verify with:"
        print -u2 "    security find-identity -v -p codesigning"
        exit 2
    fi

    if (( ${#developer_id_identities} > 1 )); then
        print -u2 "Error: several Developer ID Application certificates are installed:"
        printf '    %s\n' "${developer_id_identities[@]}" >&2
        print -u2 "Choose one with CARGODECK_SIGNING_IDENTITY."
        exit 2
    fi

    signing_identity="${developer_id_identities[1]}"
fi

team_id="${CARGODECK_TEAM_ID:-}"
if [[ -z "$team_id" ]]; then
    team_id="$(/usr/bin/sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \([A-Za-z0-9]*\);.*/\1/p' \
        "$project_root/CargoDeck.xcodeproj/project.pbxproj" | /usr/bin/head -1)"
fi
[[ -n "$team_id" ]] || fail "Could not determine the Team ID. Set CARGODECK_TEAM_ID."

# Pick the notary credentials once so both submissions use the same account.
typeset -a notary_credentials
if [[ -n "${CARGODECK_NOTARY_KEY:-}" ]]; then
    [[ -n "${CARGODECK_NOTARY_KEY_ID:-}" && -n "${CARGODECK_NOTARY_ISSUER:-}" ]] \
        || fail "CARGODECK_NOTARY_KEY also needs CARGODECK_NOTARY_KEY_ID and CARGODECK_NOTARY_ISSUER."
    notary_credentials=(
        --key "$CARGODECK_NOTARY_KEY"
        --key-id "$CARGODECK_NOTARY_KEY_ID"
        --issuer "$CARGODECK_NOTARY_ISSUER"
    )
    notary_credentials_source="App Store Connect API key $CARGODECK_NOTARY_KEY_ID"
elif [[ -n "${CARGODECK_APPLE_ID:-}" ]]; then
    [[ -n "${CARGODECK_APP_PASSWORD:-}" ]] \
        || fail "CARGODECK_APPLE_ID also needs CARGODECK_APP_PASSWORD (an app-specific password)."
    notary_credentials=(
        --apple-id "$CARGODECK_APPLE_ID"
        --password "$CARGODECK_APP_PASSWORD"
        --team-id "$team_id"
    )
    notary_credentials_source="Apple ID $CARGODECK_APPLE_ID"
else
    notary_credentials=(--keychain-profile "$notary_profile")
    notary_credentials_source="keychain profile $notary_profile"
fi

# Apple returns HTTP 403 "a required agreement is missing or has expired" when
# the team the request resolved to has no in-effect Program License Agreement.
# It is an account problem, not a problem with the artifact or the credentials.
print_notary_agreement_help() {
    print -u2 ""
    print -u2 "The Apple notary service rejected the account, not the build."
    print -u2 ""
    print -u2 "  - Confirm the request used the team that owns the Developer ID certificate"
    print -u2 "    ($team_id). An Apple ID on several teams resolves to the wrong one when"
    print -u2 "    --team-id is missing, and a personal team has no agreement in effect."
    print -u2 "  - Sign in to https://appstoreconnect.apple.com as the Account Holder, accept"
    print -u2 "    anything shown on first login, then check Business > Agreements for an"
    print -u2 "    active Apple Developer Program License Agreement."
    print -u2 "  - Check https://developer.apple.com/account for a \"Review Agreement\" banner."
    print -u2 "  - Notary access can trail a fresh enrollment by 24-48 hours even once"
    print -u2 "    certificates issue. If the agreements are active, wait and retry."
    print -u2 ""
    print -u2 "Check the account without building anything, using the same credentials"
    print -u2 "($notary_credentials_source):"
    print -u2 "    xcrun notarytool history ..."
}

print_notary_credentials_help() {
    print -u2 ""
    print -u2 "Store notary credentials once with an app-specific password from"
    print -u2 "https://account.apple.com (Sign-In and Security > App-Specific Passwords):"
    print -u2 "    xcrun notarytool store-credentials $notary_profile \\"
    print -u2 "        --apple-id <your Apple ID> --team-id $team_id --password <app-specific password>"
    print -u2 ""
    print -u2 "Or export CARGODECK_NOTARY_KEY, CARGODECK_NOTARY_KEY_ID, and"
    print -u2 "CARGODECK_NOTARY_ISSUER to use an App Store Connect API key instead."
}

# Submits $1 to the notary service and staples the ticket to $3, which is the
# submitted artifact itself unless a separate one is given. A zip is only a
# transport for the app inside it, so the ticket belongs on the app.
notarize() {
    local artifact="$1" label="$2" staple_target="${3:-$1}"
    local response_path="$project_root/build/notarytool-$label.txt"
    local submission_id="" exit_status=0

    print "Submitting $label to the Apple notary service ($notary_credentials_source). This usually takes a few minutes."
    set +e
    /usr/bin/xcrun notarytool submit "$artifact" \
        "${notary_credentials[@]}" \
        --wait \
        --timeout 30m 2>&1 | /usr/bin/tee "$response_path"
    exit_status=${pipestatus[1]}
    set -e

    submission_id="$(/usr/bin/sed -n 's/^ *id: \([0-9a-fA-F-]\{36\}\).*/\1/p' "$response_path" | /usr/bin/head -1)"

    if (( exit_status != 0 )) || ! /usr/bin/grep -q 'status: Accepted' "$response_path"; then
        if /usr/bin/grep -qi 'required agreement' "$response_path"; then
            print_notary_agreement_help
        elif [[ -n "$submission_id" ]]; then
            print -u2 ""
            print -u2 "Notary log for submission $submission_id:"
            /usr/bin/xcrun notarytool log "$submission_id" "${notary_credentials[@]}" >&2 || true
        else
            print_notary_credentials_help
        fi
        fail "Notarization of $label failed."
    fi

    /usr/bin/xcrun stapler staple "$staple_target"
    /usr/bin/xcrun stapler validate "$staple_target"
}

print "Signing identity: $signing_identity"
print "Team ID: $team_id"

rm -rf "$archive_path"
# SwiftTerm ships a SwiftPM build plugin that generates its build-info source.
# Xcode asks for that plugin to be trusted interactively the first time, which a
# scripted build cannot answer, so validation is skipped here. The package is
# pinned by Package.resolved, so what runs is the revision the repository
# recorded rather than whatever the tag points at today.
xcodebuild archive \
    -quiet \
    -project "$project_root/CargoDeck.xcodeproj" \
    -scheme "CargoDeck" \
    -configuration Release \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data_path" \
    -skipPackagePluginValidation \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    DEVELOPMENT_TEAM="$team_id" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

[[ -d "$archive_path" ]] || fail "Archive not found: $archive_path"

mkdir -p "$export_path" "$project_root/build"
rm -rf "$app_path" "$dmg_staging_path"
rm -f "$distribution_path" "$legacy_distribution_path" "$legacy_checksum_path" "$notarization_zip_path"

# Export with the Developer ID method so xcodebuild re-signs the app the way
# Apple's notary service expects, using the resolved Team ID.
[[ -f "$export_options_template" ]] || fail "Export options plist not found: $export_options_template"
/bin/cp "$export_options_template" "$export_options_path"
/usr/libexec/PlistBuddy -c "Set :teamID $team_id" "$export_options_path" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$export_options_path" >/dev/null

rm -rf "$export_path/CargoDeck.app" "$export_path/DistributionSummary.plist" \
    "$export_path/ExportOptions.plist" "$export_path/Packaging.log"
xcodebuild -exportArchive \
    -quiet \
    -archivePath "$archive_path" \
    -exportOptionsPlist "$export_options_path" \
    -exportPath "$export_path"

[[ -d "$app_path" ]] || fail "Exported app not found: $app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --verbose=4 "$app_path" 2>&1 | tee "$project_root/build/codesign-app.txt"

# Notarization rejects anything that is not Developer ID signed, hardened, and
# secure-timestamped, so check all three before spending a round trip on it.
grep -q 'Authority=Developer ID Application' "$project_root/build/codesign-app.txt" \
    || fail "$app_path is not signed with a Developer ID Application certificate."
grep -q 'flags=.*runtime' "$project_root/build/codesign-app.txt" \
    || fail "$app_path was signed without the Hardened Runtime."
grep -q '^Timestamp=' "$project_root/build/codesign-app.txt" \
    || fail "$app_path was signed without a secure timestamp."

if (( skip_notarization )); then
    print "Skipping notarization at your request."
else
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notarization_zip_path"
    notarize "$notarization_zip_path" "app" "$app_path"
    rm -f "$notarization_zip_path"
fi

mkdir -p "$dmg_staging_path"
/usr/bin/ditto "$app_path" "$dmg_staging_path/CargoDeck.app"
/bin/ln -s /Applications "$dmg_staging_path/Applications"

if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
    /usr/sbin/diskutil image create from \
        --volumeName "CargoDeck" \
        --format UDZO \
        "$dmg_staging_path" \
        "$distribution_path"
else
    /usr/bin/hdiutil create \
        -volname "CargoDeck" \
        -srcfolder "$dmg_staging_path" \
        -format UDZO \
        -ov \
        "$distribution_path"
fi

/usr/bin/hdiutil verify "$distribution_path"
rm -rf "$dmg_staging_path"

# The disk image is a separate artifact from the app, so it needs its own
# signature and its own notarization ticket.
codesign --sign "$signing_identity" --timestamp --force "$distribution_path"
codesign --verify --strict --verbose=2 "$distribution_path"

if (( ! skip_notarization )); then
    notarize "$distribution_path" "dmg"
fi

print ""
if (( skip_notarization )); then
    print "Developer ID signed app: $app_path"
    print "Distribution image: $distribution_path"
    print "SHA-256:"
    /usr/bin/shasum -a 256 "$distribution_path"
    print ""
    print -u2 "Warning: notarization was skipped. This build must not be published."
    exit 0
fi

# Confirm Gatekeeper accepts both artifacts the way a first-launch user would.
spctl --assess --type execute --verbose=4 "$app_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$distribution_path"

print ""
print "Developer ID signed, notarized, and stapled."
print "App: $app_path"
print "Distribution image: $distribution_path"
print "SHA-256:"
/usr/bin/shasum -a 256 "$distribution_path"
