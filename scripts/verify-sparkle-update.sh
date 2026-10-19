#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[sparkle-verify] skip: Sparkle bundle verification requires macOS"
  exit 0
fi

./bundle.sh

APP="target/MD Preview.app"
PLIST="$APP/Contents/Info.plist"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

test -x "$APP/Contents/MacOS/md-preview"
test -d "$FRAMEWORK"
test -x "$FRAMEWORK/Sparkle"
test -x "$FRAMEWORK/Autoupdate"
test -d "$FRAMEWORK/Updater.app"

/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" | grep -qx 'https://github.com/vorojar/md-preview/releases/latest/download/appcast.xml'
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" | grep -qx 'fstkwGnjUNSrHFW4oq3LpBMQ1dhh9lQtax5K7nI0uoQ='
/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$PLIST" | grep -qx 'true'
/usr/libexec/PlistBuddy -c 'Print :SUEnableInstallerLauncherService' "$PLIST" | grep -qx 'true'

BENCH_OUTPUT="$(MD_PREVIEW_BENCH=1 MD_PREVIEW_ENABLE_SPARKLE_INSTALLER=1 MD_PREVIEW_ALLOW_NON_APPLICATIONS_UPDATER=1 "$APP/Contents/MacOS/md-preview" 2>&1)"
grep -q 'native_updater_started' <<<"$BENCH_OUTPUT"

if command -v node >/dev/null 2>&1; then
  node - <<'NODE'
const fs = require('fs');
Object.defineProperty(global, 'navigator', {
  value: { platform: 'MacIntel', userAgent: 'Mac OS' },
  configurable: true
});
global.window = {
  localStorage: { getItem() { return null; }, setItem() {} },
  ipc: { postMessage(value) { window.sent = value; } }
};
global.requestAnimationFrame = cb => cb();
global.requestIdleCallback = cb => cb();
global.fetch = () => Promise.reject(new Error('skip network'));
const label = { textContent: '' };
const button = {
  dataset: {},
  hidden: true,
  parentElement: { classList: { add(name) { button.parentClass = name; } } },
  addEventListener(type, cb) { this.click = cb; },
  setAttribute(name, value) { this[name] = value; },
  querySelector(selector) { return selector === '.update-label' ? label : null; }
};
global.document = { getElementById() { return button; } };
eval(fs.readFileSync('assets/enhance/update-check.js', 'utf8'));
window.__mdPreviewInstallUpdateCheck({
  currentVersion: '1.1.15',
  nativeUpdater: false,
  buttonLabel: 'Update'
});
window.__mdPreviewApplyUpdateRelease({
  tag_name: 'v1.1.16',
  html_url: 'https://github.com/vorojar/md-preview/releases/tag/v1.1.16',
  assets: [{
    name: 'MD-Preview-macOS-universal.dmg',
    browser_download_url: 'https://github.com/vorojar/md-preview/releases/download/v1.1.16/MD-Preview-macOS-universal.dmg'
  }]
});
button.click();
const expected = 'open-url:https://github.com/vorojar/md-preview/releases/download/v1.1.16/MD-Preview-macOS-universal.dmg';
if (window.sent !== expected) {
  throw new Error(`unexpected macOS update IPC: ${window.sent}`);
}
if (label.textContent !== 'Update' || button.hidden !== false || button.parentClass !== 'has-update') {
  throw new Error('macOS update button state did not update');
}
NODE
fi

if [ -f target/MD-Preview-macOS-universal.dmg ]; then
  APPCAST="target/test-appcast.xml"
  ./scripts/generate-appcast.sh "v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" \
    target/MD-Preview-macOS-universal.dmg "$APPCAST" >/dev/null
  python3 - <<'PY'
from pathlib import Path
import re
xml = Path("target/test-appcast.xml").read_text()
assert "sparkle:edSignature" in xml
assert "MD-Preview-macOS-universal.dmg" in xml
assert re.search(r"<sparkle:version>[^<]+</sparkle:version>", xml)
PY
fi

echo "[sparkle-verify] OK"
