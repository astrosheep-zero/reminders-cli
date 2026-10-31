#!/bin/bash
# Build/sign only our local distribution. Never install, launch, or request access.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo 'Requires macOS 26+ on Apple silicon.' >&2; exit 1;
}
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
[[ ! -L dist && ! -L dist/reminder ]] || {
    echo 'Refusing symlinked distribution directory or wrapper.' >&2; exit 1;
}
mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Reminder.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/reminder" "$app/Contents/MacOS/reminder"
cp Resources/Info.plist "$app/Contents/Info.plist"
notices="$app/Contents/Resources/Licenses"
mkdir -p "$notices"
cp LICENSE "$notices/reminders-cli.txt"
while IFS= read -r -d '' notice; do
    relative="${notice#.build/checkouts/}"
    mkdir -p "$notices/$(dirname "$relative")"
    cp "$notice" "$notices/$relative"
done < <(find .build/checkouts -type f \( -iname 'LICENSE*' -o -iname 'NOTICE*' \) -not -path '*/.git/*' -print0)
build_id="$(uuidgen)"
/usr/libexec/PlistBuddy -c "Set :ReminderBuildID $build_id" "$app/Contents/Info.plist"
identity="${SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -f "$HOME/.config/reminders-cli/signing-identity" ]]; then
    identity="$(< "$HOME/.config/reminders-cli/signing-identity")"
    [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]] || {
        echo 'Invalid local signing fingerprint; refusing ad-hoc fallback.' >&2; exit 1;
    }
fi
identity="${identity:--}"
if [[ "$identity" == - ]]; then
    echo 'WARNING: ad-hoc signing is for this POC only; rebuilds may invalidate TCC consent.' >&2
fi
codesign --force --sign "$identity" --options runtime \
    --entitlements Resources/Reminder.entitlements "$app"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --strict "$app"
# Replace local build output only. No Applications/PATH/keychain/TCC changes.
if [[ -e dist/Reminder.app ]]; then
    [[ -d dist/Reminder.app && ! -L dist/Reminder.app ]] || {
        echo 'Refusing unexpected dist/Reminder.app file or symlink.' >&2; exit 1;
    }
    rm -rf dist/Reminder.app
fi
mv "$app" dist/Reminder.app
cat > dist/reminder <<'WRAPPER'
#!/bin/sh
set -eu
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$here/Reminder.app/Contents/MacOS/reminder" "$@"
WRAPPER
chmod 755 dist/reminder
printf 'Built dist/Reminder.app and dist/reminder (buildID %s). Not installed.\n' "$build_id"
