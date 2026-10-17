#!/bin/zsh
# Build HuskDroid.ipa for sideloading.
#   src/huskdroid/build.sh [OUT.ipa]      (default ~/Desktop/HuskDroid-VERSION-(BUILD).ipa)
# The companion token is read from the vault and handed to xcodebuild through the environment,
# so it is never on a command line or in a tracked file.
set -eu
HERE=${0:A:h}
ROOT=${HERE:h:h}
DD=$ROOT/build/dd-huskdroid

if [[ -z ${PERLICA_SECRET:-} ]]; then
  exec $HOME/.local/bin/perlica-secret run huskdroid.token -- /bin/zsh $0 "$@"
fi
export HUSKDROID_TOKEN=$PERLICA_SECRET
unset PERLICA_SECRET
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}

cd $HERE
# Version from project.yml; build number = the fork's commit count, so it only rises and names a commit.
VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
BUILD=$(git -C $ROOT rev-list --count HEAD)
OUT=${1:-$HOME/Desktop/HuskDroid-$VERSION-($BUILD).ipa}
echo "==> HuskDroid $VERSION ($BUILD), $(git -C $ROOT rev-parse --short HEAD)$(git -C $ROOT diff --quiet || echo '-dirty')"
echo "==> generating the project"
xcodegen generate --quiet
echo "==> building"
xcodebuild -project HuskDroid.xcodeproj -scheme HuskDroid -sdk iphoneos -configuration Release \
  -derivedDataPath $DD CURRENT_PROJECT_VERSION=$BUILD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > $DD.log 2>&1 || true
grep -q 'BUILD SUCCEEDED' $DD.log || { grep -E 'error:' $DD.log | head -20; echo "build failed (log: $DD.log)"; exit 1; }

APP=$DD/Build/Products/Release-iphoneos/HuskDroid.app
echo "==> checking the bundle"
rc=0
for f in Frameworks/libqemu-aarch64-softmmu.dylib Frameworks/libANGLE-shared.dylib \
         edk2-aarch64-code.fd lineage-efi-vars-seed.fd lineage-vdb-seed.qcow2; do
  [[ -f $APP/$f ]] && printf '  ok       %s\n' $f || { printf '  MISSING  %s\n' $f; rc=1; }
done
# The token must have reached Info.plist (checked without printing it).
tok=$(plutil -extract HDCompanionToken raw -o - $APP/Info.plist 2>/dev/null || true)
[[ ${#tok} -ge 16 ]] && echo "  ok       companion token (${#tok} chars)" || { echo "  MISSING  companion token"; rc=1; }
unset tok
(( rc == 0 )) || exit 1

echo "==> packaging"
STAGE=$(mktemp -d $ROOT/build/stage.XXXXXX)
trap 'rm -rf $STAGE' EXIT
mkdir -p $STAGE/Payload
cp -R $APP $STAGE/Payload/
SAPP=$STAGE/Payload/HuskDroid.app
for f in $SAPP/Frameworks/*.dylib; do codesign --force --sign - --timestamp=none $f; done
codesign --force --sign - --timestamp=none --entitlements $HERE/HuskDroid/HuskDroid.entitlements $SAPP
codesign -d --entitlements - $SAPP 2>&1 | grep -qE 'get-task-allow' || { echo "entitlements did not embed"; exit 1; }
rm -f "$OUT"
(cd $STAGE && zip -qry "$OUT" Payload)
# Older builds on the Desktop only cause mix-ups.
for old in $HOME/Desktop/HuskDroid*.ipa(N); do [[ $old != $OUT ]] && rm -f $old; done
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
