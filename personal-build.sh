#!/bin/bash
# Personal build: sync with Upstream, test, build, verify the signature, install over /Applications/AltTab.app.
set -euo pipefail
cd "$(dirname "$0")"

app=DerivedData/Build/Products/Debug/AltTab.app
fail() { echo "FAIL: $*" >&2; exit 1; }

# a. Preflight
[[ $(uname) == Darwin ]] || fail "not macOS"
# Capture before grepping: `cmd | grep -q` SIGPIPEs cmd on the first match, and pipefail turns that into a failure.
xcode=$(xcodebuild -version)
grep -q '^Xcode 26\.' <<<"$xcode" || fail "Xcode 26.x required"
ids=$(security find-identity -v -p codesigning)
grep -q '"Local Self-Signed"' <<<"$ids" || fail "Local Self-Signed signing identity missing"
python3 --version >/dev/null || fail "python3 missing"
[[ $(git remote get-url origin) == *nathanwcyang/alt-tab-nathan* ]] || fail "origin is not the fork"
[[ -z $(git status --porcelain) ]] || fail "working tree not clean"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/lwouis/alt-tab-macos.git
[[ $(git branch --show-current) == personal ]] || fail "not on branch personal"
# macOS privacy blocks xctest from reading ~/Documents, so the tests fail there with "Failed to create a bundle instance".
[[ $PWD != "$HOME"/Documents/* ]] || fail "repo is under ~/Documents; move it (e.g. to ~/Developer)"
echo "OK preflight"

# b. Sync with Upstream
git fetch upstream
if ! git merge --no-edit upstream/master; then
  git diff --name-only --diff-filter=U
  git merge --abort || true
  fail "merge conflict with upstream/master (files above); merge aborted"
fi
echo "OK merged upstream/master"
# The app crashes without a version, and PreferencesMigrations compares it with the stored preferencesVersion.
ver=$(git describe --tags --abbrev=0 HEAD | sed 's/^v//')
[[ $ver =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "bad version from the latest tag: '$ver'"
echo "OK version $ver"

# c. Tests
ai/test.sh || fail "ai/test.sh failed"
echo "OK tests passed"

# d. Build
# shortcut: mirrors ai/build.sh plus CURRENT_PROJECT_VERSION (it takes no arguments), re-diff it on each sync.
# `clean`: incremental builds alternate between re-embedding Sparkle unsigned and re-signing it, because the
# "Copy Sparkle Helpers" phase doesn't list the embedded framework as an input. A clean build always runs both.
python3 scripts/assets/compile_illustrations.py --check || fail "asset check failed"
xcodebuild -project alt-tab-macos.xcodeproj -scheme Debug -configuration Debug -derivedDataPath DerivedData \
  CURRENT_PROJECT_VERSION="$ver" clean build || fail "build failed"
built=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
[[ $built == "$ver" ]] || fail "built app has version '$built', expected '$ver'"
echo "OK built $app (version $built)"

# e. Signature
codesign --verify --deep --strict "$app" || fail "codesign --verify failed"
sig=$(codesign -dv --verbose=2 "$app" 2>&1)
grep -qx 'Authority=Local Self-Signed' <<<"$sig" || fail "signature authority is not Local Self-Signed"
echo "OK signed: Authority=Local Self-Signed"

# f. Quit the running AltTab (osascript only when running: it would otherwise launch the app)
if pgrep -x AltTab >/dev/null; then
  osascript -e 'tell application id "com.lwouis.alt-tab-macos" to quit'
  for _ in {1..10}; do pgrep -x AltTab >/dev/null || break; sleep 1; done
  if pgrep -x AltTab >/dev/null; then fail "AltTab still running after 10 seconds"; fi
fi
echo "OK AltTab not running"

# g. Back up the installed app as a zip: launchers and LaunchServices don't see an app inside a zip.
# Only the newest backup is kept; older ones and the replaced app go to the Trash, never rm.
stamp=$(date +%Y%m%d-%H%M%S)
backup=none
if [[ -e /Applications/AltTab.app ]]; then
  mkdir -p ~/AltTab-backups
  backup=~/AltTab-backups/AltTab-$stamp.zip
  ditto -c -k --keepParent /Applications/AltTab.app "$backup"
  unzip -tq "$backup" >/dev/null || fail "backup zip is unreadable: $backup"
  for old in ~/AltTab-backups/*; do [[ $old == "$backup" ]] || mv "$old" ~/.Trash/; done
  mv /Applications/AltTab.app ~/.Trash/AltTab-replaced-$stamp.app
fi
echo "OK backup: $backup"

# h. Install, and unregister the build copy so only /Applications/AltTab.app is launchable
ditto "$app" /Applications/AltTab.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app"
echo "OK installed /Applications/AltTab.app"

# i. Launch
open /Applications/AltTab.app
sleep 5
pgrep -x AltTab >/dev/null || fail "AltTab is not running after launch"
echo "OK AltTab running"

# Tag the good build: git is the real rollback (check out the tag and rebuild).
git tag "personal-$stamp"
echo "OK tagged personal-$stamp"

# j. Next steps
echo "Next: grant Accessibility and Screen Recording to AltTab in System Settings > Privacy & Security. Then open AltTab Settings, confirm Pro is on, and test search by typing in the switcher. Previous app backup: $backup (unzip it into /Applications to roll back)."
