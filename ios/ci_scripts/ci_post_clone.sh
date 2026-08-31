#!/bin/zsh
# Xcode Cloud setup - everything xcodebuild needs that is not in the clone.
#
# Location contract: Xcode Cloud looks for ci_scripts/ in the same directory as
# the .xcworkspace it builds. That is ios/, so this file is ios/ci_scripts/ and
# package.json is one level up. Every path is derived from
# $CI_PRIMARY_REPOSITORY_PATH, never from `cd ..`.
#
# Must be committed with mode 100755. `git update-index --chmod=+x` if unsure.
set -euo pipefail

REPO="${CI_PRIMARY_REPOSITORY_PATH:?not running under Xcode Cloud - CI_PRIMARY_REPOSITORY_PATH is unset}"
cd "$REPO"

NODE_VERSION="18.20.8"
NODE_DIR="$REPO/.ci-node"

say () { printf '\n== %s\n' "$*"; }
ok  () { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
die () { printf '  FAIL  %s\n' "$*" >&2; exit 1; }

say "context"
ok "repo    $REPO"
ok "arch    $(uname -m)"
ok "xcode   $(xcodebuild -version 2>/dev/null | head -1)"
ok "build   ${CI_BUILD_NUMBER:-unset} of ${CI_WORKFLOW:-unknown}"

# --------------------------------------------------------------------- node
say "node $NODE_VERSION"
# Not `brew install node@18`: Homebrew on the image is slow, billed against the
# 25 free compute hours, and unpromised. Digests below are the published
# SHASUMS256.txt values for v18.20.8.
case "$(uname -m)" in
  arm64)  node_arch="darwin-arm64"
          node_sha="bae4965d29d29bd32f96364eefbe3bca576a03e917ddbb70b9330d75f2cacd76" ;;
  x86_64) node_arch="darwin-x64"
          node_sha="ed2554677188f4afc0d050ecd8bd56effb2572d6518f8da6d40321ede6698509" ;;
  *)      die "unsupported build machine architecture: $(uname -m)" ;;
esac

if [ -x "$NODE_DIR/bin/node" ] && [ "$("$NODE_DIR/bin/node" --version 2>/dev/null)" = "v$NODE_VERSION" ]; then
  ok "node $NODE_VERSION already unpacked at $NODE_DIR"
else
  tarball="$REPO/.ci-node.tar.gz"
  url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${node_arch}.tar.gz"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 -o "$tarball" "$url" \
    || die "could not download $url"
  actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  [ "$actual" = "$node_sha" ] || die "node tarball digest mismatch: got $actual, pinned $node_sha"
  rm -rf "$NODE_DIR" && mkdir -p "$NODE_DIR"
  tar -xzf "$tarball" -C "$NODE_DIR" --strip-components=1 || die "could not unpack $tarball"
  rm -f "$tarball"
  ok "node $NODE_VERSION unpacked at $NODE_DIR (digest verified)"
fi
export PATH="$NODE_DIR/bin:$PATH"
ok "node $(node --version) / npm $(npm --version)"

# ------------------------------------------------------------------- npm ci
say "npm ci"
# package.json postinstall is:
#   patch-package && npm run jetify && sh tools/talisman/talisman-precommit.sh
# The talisman script is invoked BY PATH, so shadowing a `talisman` binary on
# PATH does nothing. Its own guard is `[ -z $GITHUB_ACTIONS ]`: every branch
# (rm .git/hooks/*, curl thoughtworks.github.io, run the installer) is skipped
# when GITHUB_ACTIONS is non-empty. Setting it here is the whole fix, and it
# removes a network dependency from the critical path.
export GITHUB_ACTIONS=1
export CI=true
export ENABLE_AUTH=false
export npm_config_fund=false npm_config_audit=false npm_config_progress=false

# Several locked transitive packages use git+ssh URLs for public GitHub repos.
# Xcode Cloud has repository access for this checkout, not a general-purpose SSH
# key for unrelated public repos, so npm would fail before CocoaPods starts.
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global --add url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "git://github.com/"

# `npm ci`, not `npm install`: package-lock.json (lockfileVersion 2) is the pin.
# Ignore lifecycle scripts because the legacy telemetry git dependency pulls in
# phantomjs-prebuilt, whose installer downloads an abandoned binary and hangs on
# current runners. The only repository build steps we need are applied explicitly.
[ -f "$REPO/package-lock.json" ] || die "no package-lock.json at $REPO"
npm ci --ignore-scripts || die "npm ci failed"
"$REPO/node_modules/.bin/patch-package" --error-on-fail || die "patch-package failed"
"$REPO/node_modules/.bin/jetify" || die "jetify failed"
ok "node_modules: $(find "$REPO/node_modules" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ') top-level entries"

# --------------------------------------------------------------------- .env
say ".env"
# react-native-dotenv resolves these at BABEL time, inside xcodebuild's
# "Bundle React Native code and images" phase. babel.config.js sets
# allowUndefined:true, so a missing key compiles to `undefined` with no error -
# the app ships pointing at nothing and the build is green.
#
# Key set is exactly types/react-native-dotenv/index.d.ts. A committed .env
# already carries the pilot values, so the workflow variables are an override,
# not a requirement.
: "${MIMOTO_HOST:=https://inji.azertica.com}"
: "${ESIGNET_HOST:=https://esignet-mock.collab.mosip.net}"

umask 077
cat > "$REPO/.env" <<EOF
MIMOTO_HOST=${MIMOTO_HOST}
ESIGNET_HOST=${ESIGNET_HOST}
OBSRV_HOST=${OBSRV_HOST:-}
APPLICATION_THEME=${APPLICATION_THEME:-purple}
APPLICATION_LANGUAGE=${APPLICATION_LANGUAGE:-en}
CREDENTIAL_REGISTRY_EDIT=${CREDENTIAL_REGISTRY_EDIT:-false}
DEBUG_MODE=${DEBUG_MODE:-false}
LIVENESS_DETECTION=${LIVENESS_DETECTION:-false}
ENABLE_OPENID_FOR_VC=${ENABLE_OPENID_FOR_VC:-true}
GOOGLE_ANDROID_CLIENT_ID=${GOOGLE_ANDROID_CLIENT_ID:-}
EOF
umask 022
ok "rendered .env  MIMOTO_HOST=$MIMOTO_HOST  ESIGNET_HOST=$ESIGNET_HOST  THEME=${APPLICATION_THEME:-purple}"

# ------------------------------------------------------- xcodebuild's node
say "xcode.env.local"
# The bundle phase sources ios/.xcode.env then ios/.xcode.env.local. It is a
# separate process launched by xcodebuild and never sees the PATH exported
# above, so NODE_BINARY has to be on disk. ios/.gitignore ignores this file,
# which is why writing it here is safe.
printf 'export NODE_BINARY="%s"\nexport NODE_ENV="production"\n' "$NODE_DIR/bin/node" > "$REPO/ios/.xcode.env.local"
ok "NODE_BINARY -> $NODE_DIR/bin/node"

# --------------------------------------------------------------- cocoapods
say "cocoapods"
if ! command -v pod >/dev/null 2>&1; then
  warn "pod not on PATH - installing cocoapods into the user gem dir (no sudo here)"
  gem install --user-install --no-document cocoapods || die "gem install cocoapods failed"
  export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
fi
ok "cocoapods $(pod --version) at $(command -v pod)"

# `pod install` with no Podfile in cwd walks UP and installs against the first
# one it finds, reporting success against a different project. Assert first.
[ -f "$REPO/ios/Podfile" ] || die "no ios/Podfile in $REPO"

# NOTE: this Podfile's post_install rewrites ios/Inji/Info.plist (adds
# ENABLE_AUTH) and calls Xcodeproj::Project.open('./Inji.xcodeproj') ...
# project.save. pod install MUTATES project.pbxproj, so stamp the build only
# after this completes.
( cd "$REPO/ios" && pod install --repo-update ) || die "pod install failed"
ok "ios/Pods: $(find "$REPO/ios/Pods" -mindepth 1 2>/dev/null | wc -l | tr -d ' ') entries, $(du -sh "$REPO/ios/Pods" 2>/dev/null | cut -f1 | tr -d ' ')"

# ------------------------------------------------------------- build number
say "build number"
# A local 0.22.1 archive used build 2608310421. Version 0.22.2 deliberately
# resets to a standards-compliant workflow build number. GitHub Actions uses
# run_number.run_attempt so a retry after a successful upload stays unique.
build_number="${INJI_BUILD_NUMBER:-${CI_BUILD_NUMBER:?CI_BUILD_NUMBER is unset}}"
[[ "$build_number" =~ '^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$' ]] \
  || die "build number must match 1-9999 with up to two numeric components: '$build_number'"
( cd "$REPO/ios" && agvtool new-version -all "$build_number" >/dev/null ) \
  || die "agvtool new-version failed"
stamped="$(cd "$REPO/ios" && agvtool what-version -terse 2>/dev/null || echo unknown)"
[ "$stamped" = "$build_number" ] \
  || die "build number did not stick: project says '$stamped', expected '$build_number'"
ok "CFBundleShortVersionString=0.22.2  CFBundleVersion=$build_number"

# --------------------------------------------------------------- final gate
say "archive gate"
[ -d "$REPO/node_modules" ] && [ -n "$(ls -A "$REPO/node_modules" 2>/dev/null)" ] \
  || die "node_modules missing after npm ci"
[ -f "$REPO/ios/Pods/Manifest.lock" ] || die "Pods/Manifest.lock missing"
cmp -s "$REPO/ios/Podfile.lock" "$REPO/ios/Pods/Manifest.lock" \
  || die "Pods/Manifest.lock differs from Podfile.lock"
for cfg in debug release; do
  [ -f "$REPO/ios/Pods/Target Support Files/Pods-Inji/Pods-Inji.$cfg.xcconfig" ] \
    || die "Pods-Inji.$cfg.xcconfig missing"
done
[ -f "$REPO/assets/models/faceModel.tflite" ] \
  || die "assets/models/faceModel.tflite missing"
[ -f "$REPO/ios/.xcode.env.local" ] || die "ios/.xcode.env.local missing"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ENABLE_AUTH' "$REPO/ios/Inji/Info.plist")" = "false" ] \
  || die "ENABLE_AUTH must remain false for the nocaps build"
ok "dependencies, Pods, model, environment, and build number are ready"

say "ci_post_clone complete"
exit 0
