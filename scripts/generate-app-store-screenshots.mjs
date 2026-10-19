import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (error) {
  console.error('Playwright is required. Run this script with NODE_PATH pointing at a temporary playwright install.');
  console.error('Example: TMP_DIR="$(mktemp -d)" && npm --prefix "$TMP_DIR" install playwright && NODE_PATH="$TMP_DIR/node_modules" node scripts/generate-app-store-screenshots.mjs');
  throw error;
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const previewUrl = pathToFileURL(path.join(repoRoot, 'mobile/shared/preview.html')).href;
const outputRoot = path.join(repoRoot, 'target/app-store-screenshots');

const devices = [
  {
    name: 'iphone',
    width: 428,
    height: 926,
    scale: 3
  },
  {
    name: 'ipad',
    width: 1024,
    height: 1366,
    scale: 2
  }
];

const mainMarkdown = `# Mermaid diagrams and KaTeX notes

> [!IMPORTANT]
> Open local Markdown files and review technical notes without sending documents to a server.

## System flow

\`\`\`mermaid
flowchart LR
  Files["Files app / Share sheet"] --> Reader["MD Preview"]
  Reader --> Render["GitHub-style Markdown"]
  Render --> Math["KaTeX notes"]
  Render --> Diagram["Mermaid diagrams"]
  Reader --> Print["Print / export"]
\`\`\`

## KaTeX-ready notes

Inline math stays readable, like $E = mc^2$ and $a^2 + b^2 = c^2$.

$$
\\sum_{i=1}^{n} i = \\frac{n(n + 1)}{2}
$$

## Review checklist

- [x] Mermaid diagrams render inline
- [x] KaTeX notes render locally
- [x] GitHub alerts, tables, code, and highlights stay readable

| Feature | Status |
| --- | --- |
| Local files | Ready |
| Search | Ready |
| Print | Ready |
`;

const searchMarkdown = `# Search technical docs fast

Find terms inside long README files, plans, and AI-generated notes.

> [!NOTE]
> Search results are highlighted in the current document without changing your file.

## Highlights

Use search for Mermaid diagrams, KaTeX notes, API names, task lists, and release plans.

\`\`\`mermaid
sequenceDiagram
  participant User
  participant Preview
  User->>Preview: Search "Mermaid"
  Preview-->>User: Highlight matching text
\`\`\`

The same document can include inline KaTeX such as $\\alpha + \\beta$ and code:

\`\`\`swift
let document = "README.md"
print(document)
\`\`\`
`;

const readmeMarkdown = `# README files stay readable

Open Markdown from Files, a share sheet, or a recent local document.

> [!TIP]
> GitHub-style alerts, task lists, tables, code, highlights, Mermaid, and KaTeX render in one clean preview.

## Release checklist

- [x] Open .md and .markdown files
- [x] Keep recent documents on device
- [x] Search inside the current document
- [x] Print or export from iOS

## Implementation notes

Use ==focused highlights== for decisions, then keep code blocks legible:

\`\`\`rust
fn render(markdown: &str) -> Preview {
    Preview::from_markdown(markdown)
}
\`\`\`

| Input | Preview support |
| --- | --- |
| GitHub alerts | Yes |
| Mermaid diagrams | Yes |
| KaTeX formulas | Yes |
| Tables and code | Yes |
`;

const chromePaths = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium'
];

async function browserOptions() {
  for (const executablePath of chromePaths) {
    try {
      await fs.access(executablePath);
      return { executablePath };
    } catch {
      // Try the next local browser.
    }
  }
  return {};
}

async function openPreview(browser, device) {
  const page = await browser.newPage({
    viewport: { width: device.width, height: device.height },
    deviceScaleFactor: device.scale,
    isMobile: device.name === 'iphone',
    hasTouch: true,
    colorScheme: 'light'
  });
  await page.goto(previewUrl, { waitUntil: 'domcontentloaded' });
  await page.emulateMedia({ colorScheme: 'light' });
  await page.waitForFunction(() => window.MDPreview && window.marked);
  return page;
}

async function renderMarkdown(page, name, markdown) {
  await page.evaluate(({ name, markdown }) => {
    window.MDPreview.render({ name, markdown, baseHref: '' });
  }, { name, markdown });
  await page.waitForFunction(() => {
    const preview = document.getElementById('preview');
    return preview && preview.children.length > 0;
  }, null, { timeout: 15000 });
}

async function waitForMathAndMermaid(page) {
  await page.waitForFunction(() => {
    const preview = document.getElementById('preview');
    return preview &&
      preview.textContent.includes('Mermaid') &&
      document.querySelector('.katex') &&
      document.querySelector('.mdp-mermaid svg');
  }, null, { timeout: 15000 });
}

async function screenshot(page, outPath) {
  await page.screenshot({ path: outPath, fullPage: false });
}

async function makeScreenshotsFor(browser, device) {
  const outDir = path.join(outputRoot, device.name);
  await fs.rm(outDir, { recursive: true, force: true });
  await fs.mkdir(outDir, { recursive: true });

  const first = await openPreview(browser, device);
  await renderMarkdown(first, 'Technical Notes.md', mainMarkdown);
  await waitForMathAndMermaid(first);
  await first.evaluate(() => window.scrollTo(0, 0));
  await screenshot(first, path.join(outDir, '01-mermaid-katex-notes.png'));
  await first.close();

  const second = await openPreview(browser, device);
  await renderMarkdown(second, 'Search Notes.md', searchMarkdown);
  await waitForMathAndMermaid(second);
  await second.locator('#search-toggle').click();
  await second.locator('#search-input').fill('Mermaid');
  await second.waitForFunction(() => document.querySelectorAll('mark.search-hit').length >= 1);
  await screenshot(second, path.join(outDir, '02-search-in-document.png'));
  await second.close();

  const third = await openPreview(browser, device);
  await renderMarkdown(third, 'README.md', readmeMarkdown);
  await third.waitForFunction(() => {
    return document.querySelector('.markdown-alert-tip') &&
      document.querySelector('mark.mdp-mark') &&
      document.querySelector('table') &&
      document.querySelector('pre code');
  });
  await screenshot(third, path.join(outDir, '03-readme-rendering.png'));
  await third.close();

  return outDir;
}

const browser = await chromium.launch({
  headless: true,
  ...(await browserOptions())
});

try {
  for (const device of devices) {
    const outDir = await makeScreenshotsFor(browser, device);
    console.log(`${device.name}: ${outDir}`);
  }
} finally {
  await browser.close();
}
