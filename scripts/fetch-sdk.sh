#!/bin/bash
# Fetch the iPhoneOS 14.5 SDK (theos/sdks) into ./sdk — only that one SDK, ~180 MB.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d sdk/iPhoneOS14.5.sdk ]; then echo "sdk/iPhoneOS14.5.sdk already present"; exit 0; fi
rm -rf sdk/.repo
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git sdk/.repo
git -C sdk/.repo sparse-checkout set iPhoneOS14.5.sdk
mv sdk/.repo/iPhoneOS14.5.sdk sdk/ && rm -rf sdk/.repo
echo "SDK ready: sdk/iPhoneOS14.5.sdk"
