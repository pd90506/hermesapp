#!/usr/bin/env bash
# Build a Release of the Mac app, sign it for Sparkle, and publish it as a GitHub release
# that installed copies update from (Apps/macOS/Updater.swift).
#
#   scripts/release-mac.sh [--dry-run] [--notes "what changed"]
#
# Run on the Mac, from a clean checkout of the commit to release (normally main). It:
#   1. numbers the build: CFBundleVersion = the commit count, so each release on main is
#      higher than the last (Sparkle compares it); the version shown is MARKETING_VERSION
#      from project.yml plus that number, e.g. 0.1.0 (110).
#   2. builds Talaria.app (Release, universal, signed by the team in Config/Local.xcconfig),
#   3. zips it and signs the zip with Sparkle's EdDSA key from the login keychain,
#   4. writes appcast.xml for this one release, and
#   5. creates release talaria-mac-<build> with both files. It is the repo's "latest"
#      release, which is what HERMES_UPDATE_FEED_URL points at.
#
# --dry-run stops before publishing and prints where the zip and appcast are.
#
# One-time setup on the release Mac:
#   - Make the key pair: after one build, run
#       <derived data>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#     It saves the private key in the login keychain and prints the public key. Back the private
#     key up (`generate_keys -x <file>`): without it, installed copies can't take new updates.
#   - In Config/Local.xcconfig set HERMES_UPDATE_FEED_URL and HERMES_UPDATE_PUBLIC_KEY (see
#     Local.xcconfig.example). The script refuses to release without them: an app built
#     without them never checks for updates.
#   - The repo's releases must be downloadable without signing in (a public repo): Sparkle
#     fetches the appcast and the zip without credentials.
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."

dry_run=0
notes=""
while (($#)); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --notes) notes="$2"; shift ;;
        *) echo "usage: $0 [--dry-run] [--notes TEXT]" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "release-mac: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || die "the checkout has uncommitted changes"
sha=$(git rev-parse HEAD)
build=$(git rev-list --count HEAD)
marketing=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]*)"?$/\1/p' project.yml | head -1)
tag="talaria-mac-$build"
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)

setting() { sed -nE "s|^ *$1 *= *(.*)$|\1|p" Config/Local.xcconfig 2>/dev/null | tail -1 | sed 's|/\$()/|//|'; }
feed=$(setting HERMES_UPDATE_FEED_URL)
key=$(setting HERMES_UPDATE_PUBLIC_KEY)
[[ -n "$feed" && -n "$key" ]] || die "set HERMES_UPDATE_FEED_URL and HERMES_UPDATE_PUBLIC_KEY in Config/Local.xcconfig"
if ((!dry_run)) && gh release view "$tag" >/dev/null 2>&1; then
    die "release $tag already exists (build $build): commit something new first"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/talaria-release.XXXXXX")
echo "release-mac: $marketing ($build) from ${sha:0:7}, working in $work"

xcodegen generate -q
# System git, and no Keychain lookup for package downloads: fetching Sparkle's binary otherwise
# waits on a Keychain access dialog nobody may be at the Mac to answer (2026-10).
xcodebuild -scmProvider system -packageAuthorizationProvider netrc -project Hermes.xcodeproj -scheme HermesMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work/dd" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" \
    build -quiet

app="$work/dd/Build/Products/Release/Talaria.app"
built_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
[[ "$built_key" == "$key" ]] || die "the built app's SUPublicEDKey doesn't match Local.xcconfig"
codesign --verify --deep --strict "$app"

zip="$work/Talaria-macOS.zip"
ditto -c -k --keepParent "$app" "$zip"

# Prints: sparkle:edSignature="…" length="…"
signature=$("$work/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" "$zip")
[[ "$signature" == *edSignature=* ]] || die "sign_update failed: run generate_keys first (see the top of this script)"

min_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
url="https://github.com/$repo/releases/download/$tag/Talaria-macOS.zip"
cat > "$work/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Talaria for Mac</title>
    <item>
      <title>$marketing ($build)</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <link>https://github.com/$repo/releases/tag/$tag</link>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$marketing</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <enclosure url="$url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF

if ((dry_run)); then
    echo "release-mac: dry run, not published:"
    echo "  $zip"
    echo "  $work/appcast.xml"
    exit 0
fi

body="Talaria for Mac $marketing ($build), built from $sha. Universal (Apple silicon + Intel), needs macOS $min_os or later.

Installed copies with in-app updates offer it on their own (Talaria ▸ Check for Updates…).

Signed with a free personal development certificate and not notarized, so macOS blocks a first install from this zip. After unzipping and moving Talaria.app to Applications, run:

    xattr -dr com.apple.quarantine /Applications/Talaria.app"
[[ -n "$notes" ]] && body="$notes

$body"

gh release create "$tag" "$zip" "$work/appcast.xml" --target "$sha" \
    --title "Talaria for Mac $marketing ($build)" --notes "$body" --latest
echo "release-mac: published $tag"
rm -rf "$work"
