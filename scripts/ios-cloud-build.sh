#!/usr/bin/env bash
set -euo pipefail

FUNOON_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FUNOON_IOS_DIR="$(cd -- "${FUNOON_SCRIPT_DIR}/../ios" && pwd)"
FUNOON_PROJECT="${FUNOON_IOS_DIR}/FunoonWorkforce.xcodeproj"
FUNOON_OUTPUT="${CM_BUILD_DIR:-${FUNOON_SCRIPT_DIR}/..}/build/ios"
FUNOON_MODE="${1:-}"

if [[ "${FUNOON_MODE}" != "verify" && "${FUNOON_MODE}" != "unsigned-device" && "${FUNOON_MODE}" != "release" ]]; then
  echo "Usage: bash scripts/ios-cloud-build.sh verify|unsigned-device|release" >&2
  exit 64
fi

python3 "${FUNOON_SCRIPT_DIR}/verify-ios-project.py"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required on the build machine. Run this workflow on Codemagic macOS; your Windows computer can start it." >&2
  exit 69
fi
mkdir -p "${FUNOON_OUTPUT}"

if [[ "${FUNOON_MODE}" == "verify" ]]; then
  xcodebuild -project "${FUNOON_PROJECT}" -scheme FunoonWorkforce \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${FUNOON_OUTPUT}/simulator" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "${FUNOON_OUTPUT}/simulator-build.log"
  ditto -c -k --sequesterRsrc --keepParent \
    "${FUNOON_OUTPUT}/simulator/Build/Products/Debug-iphonesimulator/FunoonWorkforce.app" \
    "${FUNOON_OUTPUT}/FunoonWorkforce-Simulator.zip"
  echo "Simulator compilation passed. This artifact cannot be installed on a physical iPhone."
  exit 0
fi

if [[ "${FUNOON_MODE}" == "unsigned-device" ]]; then
  # A simulator .app cannot be re-signed into an iPhone app. Compile against iphoneos.
  rm -f -- "${FUNOON_OUTPUT}/ipa/FunoonWorkforce-Unsigned.ipa"
  xcodebuild -project "${FUNOON_PROJECT}" -scheme FunoonWorkforce \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "${FUNOON_OUTPUT}/device" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    build 2>&1 | tee "${FUNOON_OUTPUT}/device-build.log"
  FUNOON_STAGING="$(mktemp -d "${FUNOON_OUTPUT}/unsigned-device.XXXXXX")"
  trap 'rm -rf -- "${FUNOON_STAGING}"' EXIT
  mkdir -p "${FUNOON_STAGING}/Payload" "${FUNOON_OUTPUT}/ipa"
  ditto "${FUNOON_OUTPUT}/device/Build/Products/Release-iphoneos/FunoonWorkforce.app" \
    "${FUNOON_STAGING}/Payload/FunoonWorkforce.app"
  ditto -c -k --norsrc --noextattr --keepParent "${FUNOON_STAGING}/Payload" \
    "${FUNOON_STAGING}/FunoonWorkforce-Unsigned.ipa"
  python3 "${FUNOON_SCRIPT_DIR}/verify-device-ipa.py" \
    "${FUNOON_STAGING}/FunoonWorkforce-Unsigned.ipa"
  mv "${FUNOON_STAGING}/FunoonWorkforce-Unsigned.ipa" \
    "${FUNOON_OUTPUT}/ipa/FunoonWorkforce-Unsigned.ipa"
  echo "Unsigned physical-device IPA prepared. Sign it locally with your Apple account before installation."
  echo "No TestFlight upload or Apple distribution signing was performed. Free provisioning expires after seven days."
  exit 0
fi

if [[ ! "${APP_STORE_APPLE_ID:-}" =~ ^[0-9]+$ ]]; then
  echo "Set APP_STORE_APPLE_ID in codemagic.yaml to the app's numeric ID from App Store Connect." >&2
  exit 64
fi
FUNOON_EFFECTIVE_BUNDLE_ID="${FUNOON_BUNDLE_ID:-com.funoon.workforce}"
if [[ ! "${FUNOON_EFFECTIVE_BUNDLE_ID}" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "FUNOON_BUNDLE_ID must be a valid Apple bundle identifier." >&2
  exit 64
fi
command -v xcode-project >/dev/null
command -v app-store-connect >/dev/null

# Mutate only the cloud checkout; never embed signing credentials in source.
python3 - "${FUNOON_PROJECT}/project.pbxproj" "${FUNOON_EFFECTIVE_BUNDLE_ID}" <<'PY'
from pathlib import Path
import re, sys
project = Path(sys.argv[1])
content, count = re.subn(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*[^;]+;',
                        'PRODUCT_BUNDLE_IDENTIFIER = ' + sys.argv[2] + ';',
                        project.read_text())
if count != 2:
    raise SystemExit('Expected exactly two target bundle identifier settings.')
project.write_text(content)
PY

# Query Apple before choosing a version; a failed query must stop the upload.
FUNOON_LATEST_BUILD="$(app-store-connect get-latest-app-store-build-number "${APP_STORE_APPLE_ID}")"
if [[ ! "${FUNOON_LATEST_BUILD}" =~ ^[0-9]+$ ]]; then
  echo "Apple did not return a numeric build number. Check the app record and API-key access." >&2
  exit 65
fi
FUNOON_BUILD_NUMBER="$((10#${FUNOON_LATEST_BUILD} + 1))"
cd "${FUNOON_IOS_DIR}"
xcode-project use-profiles
xcode-project build-ipa --project "${FUNOON_PROJECT}" --scheme FunoonWorkforce \
  --config Release --archive-xcargs "CURRENT_PROJECT_VERSION=${FUNOON_BUILD_NUMBER}" \
  --archive-directory "${FUNOON_OUTPUT}/xcarchive" \
  --ipa-directory "${FUNOON_OUTPUT}/ipa"
echo "Signed IPA exported. Install this App Store distribution build through TestFlight after Apple processing."
