#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")" && pwd)"
build_dir="${1:?Usage: build.sh BUILD_DIRECTORY [AWS_CLI_V2_PACKAGE]}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
package="${2:-$build_dir/AWSCLIV2-2.42.3.pkg}"
if [[ ! -f "$package" ]]; then
  curl --fail --location --silent --show-error \
    'https://awscli.amazonaws.com/AWSCLIV2-2.42.3.pkg' --output "$package"
fi
signature="$(pkgutil --check-signature "$package")"
if [[ "$signature" != *'Developer ID Installer: AMZN Mobile LLC (94KV3E626L)'* || "$signature" != *'Notarization: trusted'* ]]; then
  echo 'AWS CLI installer signature did not match Amazon.' >&2
  exit 1
fi
scratch="$(mktemp -d "$build_dir/cloudshelf.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
pkgutil --expand-full "$package" "$scratch/aws"
cli="$scratch/aws/aws-cli.pkg/Payload/aws-cli"
app="$scratch/s3Shelf.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project/Info.plist" "$app/Contents/Info.plist"
cp "$project/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
python3 "$project/catalog.py" "$cli" "$app/Contents/Resources/operations.json"
ditto "$cli" "$app/Contents/Resources/aws-cli"
cp "$scratch/aws/Resources/LICENSE.txt" "$app/Contents/Resources/AWS-CLI-LICENSE.txt"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 6 -O -target "$arch-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "$scratch/s3Shelf-$arch" "$project"/Sources/*.swift &
done
build_status=0
for job in $(jobs -p); do wait "$job" || build_status=1; done
[[ "$build_status" -eq 0 ]]
xcrun lipo -create "$scratch/s3Shelf-arm64" "$scratch/s3Shelf-x86_64" -output "$app/Contents/MacOS/s3Shelf"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
rm -rf "$build_dir/s3Shelf.app"
mv "$app" "$build_dir/s3Shelf.app"
