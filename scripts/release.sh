#!/bin/bash
# Builds both apps, packs them as Positives.dmg and Negatives.dmg, and publishes a GitHub release.
#
#   scripts/release.sh 1.1 "What changed, in plain words."     build, test, publish v1.1
#   scripts/release.sh 1.1 --dry-run                            build, test, make the DMGs only (in .build/release)
#
# The asset names never change: the website and README link to releases/latest/download/<name>.dmg.
# Needs: Xcode, Homebrew xcodegen, libomp, jpeg-turbo and gh (logged in as the repository owner).
set -euo pipefail

version="${1:?usage: scripts/release.sh <version> \"<notes>\" | --dry-run}"
notes="${2:?give release notes, or --dry-run}"
cd "$(dirname "$0")/.."
root="$(pwd)"
out="$root/.build/release"

# Version number shown in the apps (About window); a dry run leaves it unchanged.
if [ "$notes" != "--dry-run" ]; then
    build_number=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
    sed -i '' -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$version\"/" \
              -e "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$build_number\"/" project.yml
fi
xcodegen generate >/dev/null

echo "Testing…"
tests=$(swift test 2>&1 || true)
echo "$tests" | grep -E "Test run with|error:" || true
if echo "$tests" | grep -qE "✘|error:"; then echo "Tests failed — not releasing."; exit 1; fi

echo "Building…"
for scheme in Positives Negatives; do
    xcodebuild -project Darkroom.xcodeproj -scheme "$scheme" -configuration Release -derivedDataPath .build/xcode build \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
done
products="$root/.build/xcode/Build/Products/Release"

# The apps must not depend on anything from Homebrew at run time.
for app in "Positives - photo editor" "Negatives"; do
    if otool -L "$products/$app.app/Contents/MacOS/$app" | grep -q /opt/homebrew; then
        echo "$app links a Homebrew library — not releasing."; exit 1
    fi
done

echo "Packing…"
rm -rf "$out" && mkdir -p "$out"
pack() {  # <app bundle name> <dmg / volume name>
    local stage="$out/stage-$2"
    mkdir -p "$stage" && cp -R "$products/$1.app" "$stage/" && ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "$2" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out/$2.dmg"
    hdiutil verify -quiet "$out/$2.dmg"
    rm -rf "$stage"
}
pack "Positives - photo editor" Positives
pack "Negatives" Negatives
ls -lh "$out"/*.dmg

if [ "$notes" = "--dry-run" ]; then echo "Dry run: DMGs are in $out"; exit 0; fi

git add project.yml Darkroom.xcodeproj
git commit -m "Version $version" >/dev/null || true
git push origin main
gh release create "v$version" "$out/Positives.dmg" "$out/Negatives.dmg" --target main \
    --title "Positives & Negatives $version" --notes "$notes

**Download:** [Positives.dmg](https://github.com/giaggito/Negatives-Positives/releases/download/v$version/Positives.dmg) · [Negatives.dmg](https://github.com/giaggito/Negatives-Positives/releases/download/v$version/Negatives.dmg)

Install: open the file and drag the app to Applications. The first time, open it, click Done, then System Settings → Privacy & Security → Open Anyway. Needs a Mac with Apple silicon and macOS 14 or newer."
echo "Published v$version."
