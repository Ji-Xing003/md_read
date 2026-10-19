#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

grep -q 'MD-Preview-windows-x64' assets/enhance/update-check.js
grep -q 'download_digest' assets/enhance/update-check.js
grep -q 'Get-FileHash' src/main.rs
grep -q 'Copy-Item -LiteralPath $tmp -Destination $target -Force' src/main.rs
grep -q 'powershell.exe' src/main.rs
grep -q 'MD-Preview-windows-x64.exe' .github/workflows/release.yml
grep -q 'MD-Preview-windows-x64-Setup.exe' .github/workflows/release.yml && {
  echo "error: Windows setup installer should not be in the release workflow" >&2
  exit 1
}
grep -q 'WinSparkle' src/main.rs && {
  echo "error: WinSparkle runtime should not be required for Windows self-update" >&2
  exit 1
}

if command -v node >/dev/null 2>&1; then
  node - <<'NODE'
const fs = require('fs');
Object.defineProperty(global, 'navigator', {
  value: { platform: 'Win32', userAgent: 'Windows' },
  configurable: true
});
global.window = {
  localStorage: { getItem() { return null; }, setItem() {} },
  ipc: { postMessage(value) { window.sent = value; } }
};
global.requestAnimationFrame = cb => cb();
global.requestIdleCallback = cb => cb();
global.fetch = () => Promise.reject(new Error('skip network'));
const button = {
  dataset: {},
  parentElement: { classList: { add() {} } },
  addEventListener(type, cb) { this.click = cb; },
  setAttribute() {}
};
global.document = { getElementById() { return button; } };
eval(fs.readFileSync('assets/enhance/update-check.js', 'utf8'));
window.__mdPreviewInstallUpdateCheck({ currentVersion: '1.1.11', nativeUpdater: true });
window.__mdPreviewApplyUpdateRelease({
  tag_name: 'v1.1.12',
  assets: [{
    name: 'MD-Preview-windows-x64.exe',
    browser_download_url: 'https://github.com/vorojar/md-preview/releases/download/v1.1.12/MD-Preview-windows-x64.exe',
    digest: 'sha256:' + 'a'.repeat(64)
  }]
});
button.click();
if (!window.sent || !window.sent.includes('MD-Preview-windows-x64.exe') || !window.sent.includes('sha256:')) {
  throw new Error(`bad update IPC: ${window.sent}`);
}
NODE
fi

echo "[windows-self-update-verify] OK"
