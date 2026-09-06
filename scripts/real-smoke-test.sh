#!/bin/zsh

set -euo pipefail

if [[ "${CONTAINER_GUI_RUN_REAL_SMOKE:-}" != "1" ]]; then
    print -u2 "Refusing to modify containers without CONTAINER_GUI_RUN_REAL_SMOKE=1."
    exit 2
fi

cli="${CONTAINER_GUI_CLI:-/usr/local/bin/container}"
image="${CONTAINER_GUI_SMOKE_IMAGE:-alpine:3.21}"
resource="container-gui-smoke-$(date +%Y%m%d%H%M%S)-$$"
delete_pulled_image=0
container_was_created=0
network_was_created=0
# The archive round-trip works on a throwaway tag of the image that is already
# being pulled, so it never prunes and never touches an unrelated image.
smoke_tag="container-gui-smoke:${resource##*-}"
tag_was_created=0
archive_path=""

if [[ ! -x "$cli" ]]; then
    print -u2 "Apple Container executable is not executable: $cli"
    exit 2
fi

cleanup() {
    local status=$?
    set +e
    if (( container_was_created )); then
        "$cli" stop "$resource" >/dev/null 2>&1
        "$cli" delete --force "$resource" >/dev/null 2>&1
    fi
    if (( network_was_created )); then
        "$cli" network delete "$resource" >/dev/null 2>&1
    fi
    if (( tag_was_created )); then
        "$cli" image delete "$smoke_tag" >/dev/null 2>&1
    fi
    if [[ -n "$archive_path" ]]; then
        rm -f "$archive_path"
    fi
    if (( delete_pulled_image )); then
        "$cli" image delete "$image" >/dev/null 2>&1
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

image_list="$("$cli" image list --verbose --format json)"
if [[ "$image_list" != *"$image"* ]]; then
    delete_pulled_image=1
fi

"$cli" system version --format json
"$cli" system status --format json
"$cli" image pull --progress plain "$image"
"$cli" network create --label "com.container-gui.smoke=true" "$resource"
network_was_created=1
"$cli" network list --format json
"$cli" network inspect "$resource"
"$cli" run --progress plain --detach --name "$resource" --network "$resource" "$image"
container_was_created=1
"$cli" list --all --format json
"$cli" inspect "$resource"
"$cli" logs "$resource"
"$cli" stats --format json --no-stream "$resource"
"$cli" stop "$resource"
"$cli" delete "$resource"
container_was_created=0
"$cli" network delete "$resource"
network_was_created=0

# Image archive round-trip: tag, save, remove only that tag, load it back, and
# confirm the tag returns. Nothing here prunes, and no image other than the
# throwaway tag is ever deleted.
archive_path="$(mktemp -t container-gui-smoke).tar"
"$cli" image tag "$image" "$smoke_tag"
tag_was_created=1
"$cli" image save --output "$archive_path" "$smoke_tag"
if [[ ! -s "$archive_path" ]]; then
    print -u2 "image save produced no archive at $archive_path"
    exit 1
fi
"$cli" image delete "$smoke_tag"
tag_was_created=0
if "$cli" image list --format json | grep -q "$smoke_tag"; then
    print -u2 "image delete left $smoke_tag behind"
    exit 1
fi
"$cli" image load --input "$archive_path"
tag_was_created=1
if ! "$cli" image list --format json | grep -q "$smoke_tag"; then
    print -u2 "image load did not restore $smoke_tag"
    exit 1
fi
"$cli" image delete "$smoke_tag"
tag_was_created=0
rm -f "$archive_path"
archive_path=""

# Registry login, logout and push are deliberately absent: they mutate stored
# credentials or a remote registry and need a separately configured disposable
# registry. See the registry section of docs/RELEASE_CHECKLIST.md.

if (( delete_pulled_image )); then
    "$cli" image delete "$image"
    delete_pulled_image=0
fi

trap - EXIT INT TERM
print "Real CLI smoke test passed for container, network and image archive round-trip $resource using $image."
