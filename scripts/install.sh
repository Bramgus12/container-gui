#!/bin/bash
#
# Container GUI installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
#
# Downloads the released disk image, verifies its checksum and code signature,
# installs the app, and removes the com.apple.quarantine attribute so the app
# opens without a Gatekeeper detour. Container GUI is ad-hoc signed and is not
# notarized by Apple; see the README for what that means.
#
# Written for bash 3.2 so it runs on a stock macOS install.

set -euo pipefail

readonly REPO="Bramgus12/container-gui"
readonly APP_NAME="Container GUI.app"
readonly DMG_NAME="Container-GUI.dmg"
readonly PREFERENCES="$HOME/Library/Preferences/com.gussekloo.container-gui.plist"
readonly MINIMUM_MACOS_MAJOR=26

version_tag=""
install_dir="/Applications"
install_dir_explicit="false"
mode="install"

release_tag=""
download_url=""
expected_digest=""
dmg_path=""
work_dir=""
mount_point=""
staged_path=""
privileged="false"

info() {
    printf '==> %s\n' "$1"
}

warn() {
    printf 'Warning: %s\n' "$1" >&2
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<USAGE
Install Container GUI from its GitHub releases.

Usage: install.sh [options]

Options:
  --version <tag>   Install a specific release, for example --version v1.1.0.
                    Defaults to the latest release.
  --dir <path>      Install into <path> instead of /Applications.
  --user            Install into ~/Applications. Never needs an administrator
                    password.
  --uninstall       Remove an installed Container GUI.app. Settings are kept.
  -h, --help        Show this message.
USAGE
}

cleanup() {
    if [[ -n "$staged_path" && -e "$staged_path" ]]; then
        run_privileged /bin/rm -rf "$staged_path" 2>/dev/null || true
    fi
    if [[ -n "$mount_point" ]]; then
        detach_disk_image
    fi
    if [[ -n "$work_dir" ]]; then
        /bin/rm -rf "$work_dir" 2>/dev/null || true
    fi
}

run_privileged() {
    if [[ "$privileged" == "true" ]]; then
        /usr/bin/sudo "$@"
    else
        "$@"
    fi
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a release tag, for example --version v1.1.0."
            version_tag="$2"
            shift 2
            ;;
        --version=*)
            version_tag="${1#*=}"
            [[ -n "$version_tag" ]] || fail "--version requires a release tag, for example --version v1.1.0."
            shift
            ;;
        --dir)
            [[ $# -ge 2 ]] || fail "--dir requires a directory path."
            install_dir="$2"
            install_dir_explicit="true"
            shift 2
            ;;
        --dir=*)
            install_dir="${1#*=}"
            [[ -n "$install_dir" ]] || fail "--dir requires a directory path."
            install_dir_explicit="true"
            shift
            ;;
        --user)
            install_dir="$HOME/Applications"
            install_dir_explicit="true"
            shift
            ;;
        --uninstall)
            mode="uninstall"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1. Run install.sh --help for usage."
            ;;
        esac
    done
}

require_macos() {
    [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "Container GUI runs on macOS only."
}

require_supported_platform() {
    require_macos

    local architecture
    architecture="$(/usr/bin/uname -m)"
    [[ "$architecture" == "arm64" ]] \
        || fail "Container GUI requires an Apple-silicon Mac (detected $architecture)."

    local product_version major
    product_version="$(/usr/bin/sw_vers -productVersion)"
    major="${product_version%%.*}"
    case "$major" in
    '' | *[!0-9]*)
        warn "Could not read the macOS version (got '$product_version'). Continuing."
        ;;
    *)
        if [[ "$major" -lt "$MINIMUM_MACOS_MAJOR" ]]; then
            fail "Container GUI requires macOS $MINIMUM_MACOS_MAJOR or later (detected $product_version)."
        fi
        ;;
    esac
}

require_app_not_running() {
    if /usr/bin/pgrep -f "/$APP_NAME/Contents/MacOS/" >/dev/null 2>&1; then
        fail "Container GUI is running. Quit it and run this command again."
    fi
}

fetch() {
    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --retry 2 \
        --connect-timeout 15 \
        --max-time 600 \
        "$@"
}

# Reads JSON on stdin and prints the first string value for the given key.
json_string_value() {
    /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | /usr/bin/head -n 1
}

# Reads a release payload on stdin and prints the asset object holding the DMG.
# GitHub emits an asset's name before its digest and download URL, so printing
# from the matching name onward keeps this independent of the other assets.
dmg_asset() {
    /usr/bin/awk -v pattern="\"name\"[ \t]*:[ \t]*\"$DMG_NAME\"" '
        $0 ~ pattern { found = 1 }
        found { print }
    '
}

resolve_release() {
    local api_url response=""

    if [[ -n "$version_tag" ]]; then
        api_url="https://api.github.com/repos/$REPO/releases/tags/$version_tag"
    else
        api_url="https://api.github.com/repos/$REPO/releases/latest"
    fi

    response="$(fetch --header 'Accept: application/vnd.github+json' "$api_url" 2>/dev/null)" || response=""

    if [[ -z "$response" ]]; then
        if [[ -n "$version_tag" ]]; then
            fail "Could not find release $version_tag. Check the available tags at https://github.com/$REPO/releases."
        fi
        warn "The GitHub API is unavailable or rate-limited. Falling back to the latest release link without a published checksum."
        release_tag="latest"
        download_url="https://github.com/$REPO/releases/latest/download/$DMG_NAME"
        expected_digest=""
        return
    fi

    release_tag="$(printf '%s\n' "$response" | json_string_value 'tag_name')"
    [[ -n "$release_tag" ]] || release_tag="${version_tag:-latest}"

    local asset
    asset="$(printf '%s\n' "$response" | dmg_asset)"
    [[ -n "$asset" ]] \
        || fail "Release $release_tag has no $DMG_NAME asset. Download it manually from https://github.com/$REPO/releases."

    download_url="$(printf '%s\n' "$asset" | json_string_value 'browser_download_url')"
    [[ -n "$download_url" ]] || fail "Could not read the download URL for $DMG_NAME in release $release_tag."

    # The digest field is absent on older releases and null when GitHub has not
    # computed one. Either way, fall through to printing the checksum instead.
    expected_digest="$(printf '%s\n' "$asset" | json_string_value 'digest' | /usr/bin/tr '[:upper:]' '[:lower:]')"
    expected_digest="${expected_digest#sha256:}"
    case "$expected_digest" in
    *[!0-9a-f]* | '') expected_digest="" ;;
    esac
}

download_disk_image() {
    dmg_path="$work_dir/$DMG_NAME"

    info "Downloading $DMG_NAME ($release_tag)"
    fetch --output "$dmg_path" "$download_url" || fail "Could not download $download_url"

    local actual_digest
    actual_digest="$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{ print $1 }')"
    info "SHA-256: $actual_digest"

    if [[ -n "$expected_digest" ]]; then
        [[ "$actual_digest" == "$expected_digest" ]] \
            || fail "Checksum mismatch. Expected $expected_digest. Nothing was installed. Report this at https://github.com/$REPO/issues."
        info "Checksum matches the published release asset."
    else
        warn "No published checksum was available. Compare the value above with the SHA-256 in the release notes at https://github.com/$REPO/releases."
    fi
}

# macOS 26 deprecates the hdiutil attach and detach spellings in favour of
# diskutil, the same capability check scripts/release.sh makes for image
# creation. Mounting at a known path keeps this independent of either tool's
# output format.
mount_disk_image() {
    mount_point="$work_dir/mount"
    /bin/mkdir -p "$mount_point" || fail "Could not create a mount point."

    if /usr/sbin/diskutil image attach --help >/dev/null 2>&1; then
        /usr/sbin/diskutil image attach \
            --readOnly \
            --nobrowse \
            --mountPoint "$mount_point" \
            "$dmg_path" >/dev/null 2>&1 \
            || fail "Could not mount $DMG_NAME."
    else
        /usr/bin/hdiutil attach "$dmg_path" \
            -nobrowse \
            -readonly \
            -mountpoint "$mount_point" \
            -quiet \
            || fail "Could not mount $DMG_NAME."
    fi

    [[ -d "$mount_point/$APP_NAME" ]] || fail "$DMG_NAME does not contain $APP_NAME."
}

detach_disk_image() {
    if /usr/sbin/diskutil eject "$mount_point" >/dev/null 2>&1; then
        return
    fi
    /usr/bin/hdiutil detach "$mount_point" -quiet 2>/dev/null \
        || /usr/bin/hdiutil detach "$mount_point" -force -quiet 2>/dev/null \
        || true
}

verify_signature() {
    local app="$1" consequence="$2"
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
        || fail "$app failed code signature verification. $consequence"
}

resolve_install_directory() {
    if [[ "$install_dir_explicit" == "true" ]]; then
        /bin/mkdir -p "$install_dir" || fail "Could not create $install_dir."
        return
    fi

    if [[ -w "$install_dir" ]]; then
        return
    fi

    if [[ -r /dev/tty ]]; then
        info "$install_dir needs an administrator password."
        privileged="true"
        return
    fi

    install_dir="$HOME/Applications"
    warn "/Applications is not writable and no terminal is available for an administrator prompt. Installing into $install_dir instead."
    /bin/mkdir -p "$install_dir" || fail "Could not create $install_dir."
}

install_app() {
    local source="$mount_point/$APP_NAME"
    local target="$install_dir/$APP_NAME"
    staged_path="$install_dir/.$APP_NAME.install-$$"

    info "Verifying the app signature"
    verify_signature "$source" "Nothing was installed."

    info "Installing into $install_dir"
    run_privileged /bin/rm -rf "$staged_path"
    run_privileged /usr/bin/ditto "$source" "$staged_path" || fail "Could not copy $APP_NAME into $install_dir."

    if [[ -e "$target" ]]; then
        info "Replacing the existing installation"
        run_privileged /bin/rm -rf "$target" || fail "Could not remove the existing $target."
    fi

    run_privileged /bin/mv "$staged_path" "$target" || fail "Could not move $APP_NAME into place."
    staged_path=""

    info "Removing the quarantine attribute"
    run_privileged /usr/bin/xattr -d -r com.apple.quarantine "$target" >/dev/null 2>&1 || true

    verify_signature "$target" "Remove $target and report this at https://github.com/$REPO/issues."

    if /usr/bin/xattr -r -l "$target" 2>/dev/null | /usr/bin/grep -q 'com.apple.quarantine'; then
        warn "Some quarantine attributes remain. macOS may still block the first launch; approve the app in System Settings > Privacy & Security."
    fi

    local installed_version=""
    installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null)" || installed_version=""

    printf '\n'
    if [[ -n "$installed_version" ]]; then
        info "Installed Container GUI $installed_version ($release_tag) at $target"
    else
        info "Installed Container GUI ($release_tag) at $target"
    fi
    info "Open it with: open -a \"Container GUI\""
}

uninstall_app() {
    require_macos

    local candidates
    if [[ "$install_dir_explicit" == "true" ]]; then
        candidates=("$install_dir/$APP_NAME")
    else
        candidates=("/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME")
    fi

    local removed="false" candidate parent
    for candidate in "${candidates[@]}"; do
        [[ -e "$candidate" ]] || continue
        require_app_not_running

        parent="$(/usr/bin/dirname "$candidate")"
        privileged="false"
        if [[ ! -w "$parent" ]]; then
            [[ -r /dev/tty ]] || fail "$parent is not writable. Re-run this command from a terminal so it can ask for an administrator password."
            info "$parent needs an administrator password."
            privileged="true"
        fi

        run_privileged /bin/rm -rf "$candidate" || fail "Could not remove $candidate."
        info "Removed $candidate"
        removed="true"
    done

    if [[ "$removed" == "false" ]]; then
        if [[ "$install_dir_explicit" == "true" ]]; then
            info "Container GUI is not installed in $install_dir."
        else
            info "Container GUI is not installed in /Applications or ~/Applications."
        fi
        return
    fi

    info "Settings were kept at $PREFERENCES. Delete that file to reset onboarding."
}

main() {
    parse_arguments "$@"
    trap cleanup EXIT

    if [[ "$mode" == "uninstall" ]]; then
        uninstall_app
        return
    fi

    require_supported_platform
    require_app_not_running
    resolve_release

    work_dir="$(/usr/bin/mktemp -d)" || fail "Could not create a temporary directory."

    download_disk_image
    mount_disk_image
    resolve_install_directory
    install_app
}

main "$@"
