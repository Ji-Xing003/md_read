# 侧边 TOC 导航 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给预览加侧边目录 (TOC): 前端 JS 从渲染后 DOM 的 h1–h4 构建大纲, 点击滚动到章节, scrollspy 高亮当前章节, 开关状态持久化。

**Architecture:** 纯前端 DOM 方案 — 标题 id 由 pulldown-cmark 渲染器生成, DOM 是唯一真源。Rust 只改: 模板 (sidebar div + CSS + JS + 按钮)、Strings 文案、`toc-open.txt` 持久化、`build_page` 加 `toc_open` 参数、IPC `toc-state:` 分支。

**Tech Stack:** Rust + wry/tao 单文件 `src/main.rs` (~4100 行, format! 模板), 无新依赖。

## Global Constraints

- 所有改动只在 `src/main.rs` (模板是 `build_page` 内一个大 `format!(r#"..."#)` 字符串, 里面 `{{` `}}` 是转义花括号, 写 CSS/JS 时照抄这个转义规则)。
- 模板占位符 `{name}` 对应 `build_page` 末尾 `format_args!` 的参数名 — 新增占位符必须同时加参数, 否则编译错。
- JS 字符串内插值 (如 `'{toc_empty_js}'`) 必须用 `escape_js()` 包过再进 format 参数 (参照 `stat_words_js`)。
- 属性内插值照抄现有模式 (如 `title="{btn_open}"` 直接传 `s.btn_open`)。
- Windows shell: 构建用 `export PATH="$PATH:/c/Users/kduo8/.cargo/bin" && cargo build`, 测试 `cargo test`。
- 每个 task 结束 `cargo test` 全绿 + commit。git 提交消息尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。
- 现有 34 个测试必须保持通过。

---

### Task 1: Strings 文案 + toc-open 持久化辅助

**Files:**
- Modify: `D:\project\md_read\md-preview\src\main.rs` (Strings 结构体 + 两个初始化 + theme 辅助函数后新增持久化函数 + tests 模块加测试)

**Interfaces:**
- Produces: `Strings.btn_toc: &'static str`, `Strings.toc_empty: &'static str`; `fn toc_open_path() -> PathBuf`; `fn load_toc_open() -> bool` (默认 true); `fn save_toc_open(open: bool)`。

- [ ] **Step 1: 写失败测试**

在 `mod tests` 内 (找 `panic_hook_writes_reason_to_log_file` 测试后面) 加:

```rust
    #[test]
    fn toc_open_state_defaults_open_and_roundtrips() {
        let path = toc_open_path();
        let _ = fs::remove_file(&path);
        assert!(load_toc_open());

        save_toc_open(false);
        assert!(!load_toc_open());
        save_toc_open(true);
        assert!(load_toc_open());

        fs::write(&path, "garbage").unwrap();
        assert!(load_toc_open()); // 损坏内容默认打开

        let _ = fs::remove_file(&path);
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test toc_open_state_defaults_open_and_roundtrips`
Expected: FAIL, `cannot find function toc_open_path`

- [ ] **Step 3: 加 Strings 字段**

`struct Strings` (约 136 行) 在 `btn_zoom_in: &'static str,` 后加:

```rust
    btn_toc: &'static str,
    toc_empty: &'static str,
```

Zh 初始化 (`btn_zoom_in: "放大正文 (Cmd/Ctrl++)",` 后):

```rust
                btn_toc: "目录",
                toc_empty: "无标题",
```

En 初始化 (`btn_zoom_in: "Zoom in (Cmd/Ctrl++)",` 后):

```rust
                btn_toc: "Outline",
                toc_empty: "No headings",
```

- [ ] **Step 4: 加持久化函数**

`fn save_theme_choice` 结束后 (约 309 行) 加:

```rust
fn toc_open_path() -> PathBuf {
    config_dir().join("toc-open.txt")
}

fn load_toc_open() -> bool {
    fs::read_to_string(toc_open_path())
        .map(|raw| raw.trim() != "0")
        .unwrap_or(true)
}

fn save_toc_open(open: bool) {
    let dir = config_dir();
    let _ = fs::create_dir_all(&dir);
    let _ = fs::write(dir.join("toc-open.txt"), if open { "1" } else { "0" });
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cargo test`
Expected: PASS, 35 passed (34 旧 + 1 新)

- [ ] **Step 6: Commit**

```bash
git add src/main.rs
git commit -m "feat: toc open state persistence helpers and strings"
```

---

### Task 2: build_page 加 toc_open 参数 + 模板 (markup/CSS/JS/按钮)

**Files:**
- Modify: `D:\project\md_read\md-preview\src\main.rs` (build_page 签名 + body_class + 模板 CSS/markup/JS + format args + 5 处测试调用点 + 新模板测试)

**Interfaces:**
- Consumes: Task 1 的 `Strings.btn_toc` / `Strings.toc_empty`。
- Produces: `build_page(preview_html, raw_md, base_href, flags, s, empty, toc_open: bool) -> String`; body class `toc-hidden` 表示关闭; 页面暴露 `window.__mdPreviewBuildToc`; IPC 消息 `toc-state:1` / `toc-state:0`。

- [ ] **Step 1: 改 build_page 签名 + body_class**

`fn build_page(` (约 1077 行) 参数末尾加 `toc_open: bool`; body_class 行改为:

```rust
    let body_class = if empty {
        "empty"
    } else if toc_open {
        ""
    } else {
        "toc-hidden"
    };
```

- [ ] **Step 2: 模板加按钮**

模板中 (约 1410 行区域):

```html
  <button id="btn-open" title="{btn_open}" aria-label="{btn_open}"></button>
  <button id="btn-search" title="{btn_search}" aria-label="{btn_search}"></button>
  <button id="btn-toggle" title="{btn_edit}" aria-label="{btn_edit}"></button>
```

在 btn-search 与 btn-toggle 之间插:

```html
  <button id="btn-toc" title="{btn_toc}" aria-label="{btn_toc}"></button>
```

- [ ] **Step 3: 模板加 sidebar markup**

toolbar 的 `</div>` 与 `<div class="findbar"` 之间插:

```html
	<div class="toc-sidebar" id="toc-sidebar">
	  <div class="toc-list" id="toc-list"></div>
	</div>
```

- [ ] **Step 4: 加亮色 CSS**

`#preview input[type="checkbox"]` 规则后、`	.empty {{` 前插:

```css
	.toc-sidebar {{
	  position: fixed; left: 0; top: var(--chrome-top); bottom: 0; width: 232px;
	  padding: 10px 6px 10px 10px; box-sizing: border-box; overflow-y: auto;
	  border-right: 1px solid #e6e6e6; background: rgba(248,248,248,0.92);
	  z-index: 90;
	}}
	body.toc-hidden .toc-sidebar, body.empty .toc-sidebar, body.editing .toc-sidebar {{ display: none; }}
	body:not(.toc-hidden):not(.empty):not(.editing) #app {{ padding-left: 250px; }}
	#preview h1, #preview h2, #preview h3, #preview h4 {{ scroll-margin-top: calc(var(--chrome-top) + 16px); }}
	.toc-item {{
	  display: block; width: 100%; padding: 4px 8px; margin: 0; border-radius: 6px;
	  border: 0; background: none; color: #57606a; font: inherit; font-size: 13px;
	  line-height: 1.4; text-align: left; text-decoration: none; cursor: pointer;
	  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; box-sizing: border-box;
	}}
	.toc-item:hover {{ background: rgba(0,0,0,0.05); color: #1a1a1a; }}
	.toc-item.active {{ background: #e7f3ff; color: #0969da; font-weight: 600; }}
	.toc-item.l2 {{ padding-left: 22px; }}
	.toc-item.l3 {{ padding-left: 34px; }}
	.toc-item.l4 {{ padding-left: 46px; }}
	.toc-empty {{ color: #999; font-size: 13px; padding: 8px; }}
```

- [ ] **Step 5: 加暗色 CSS**

暗色块内 `.toolbar .zoom-popover button:hover {{ background: rgba(255,255,255,.1); }}` 后插:

```css
	.toc-sidebar {{ border-color: #363636; background: rgba(28,28,28,0.92); }}
	.toc-item {{ color: #9aa0a6; }}
	.toc-item:hover {{ background: rgba(255,255,255,0.06); color: #fff; }}
	.toc-item.active {{ background: rgba(56,139,253,0.18); color: #6cb6ff; }}
	.toc-empty {{ color: #777; }}
```

- [ ] **Step 6: 打印 CSS 隐藏 sidebar**

`@media print {{` 块内:

```css
  .toolbar, .tabbar, #editor {{ display: none !important; }}
```

改为:

```css
  .toolbar, .tabbar, #editor, .toc-sidebar {{ display: none !important; }}
```

(`#app {{ max-width: none; padding: 0; }}` 已有, 自动清掉 padding-left。)

- [ ] **Step 7: 加 JS (icon + DOM 引用 + buildToc + scrollspy + toggle)**

`var ICON_CLOSE = ...;` 后加:

```javascript
		  var ICON_LIST = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>';
```

`var btnZoomIn = document.getElementById('btn-zoom-in');` 后加:

```javascript
		  var btnToc = document.getElementById('btn-toc');
		  var tocList = document.getElementById('toc-list');
		  var tocScrollTimer = 0;
```

`window.__setPreview` 的定义行后 (找 `window.__setPreview = function` 所在的 JS 区域, 在闭包内任意位置放下列函数, 建议放 `window.__setTabs` 定义前):

```javascript
		function buildToc() {{
		  tocList.textContent = '';
		  var headings = document.querySelectorAll('#preview h1[id],#preview h2[id],#preview h3[id],#preview h4[id]');
		  if (!headings.length) {{
		    var empty = document.createElement('div');
		    empty.className = 'toc-empty';
		    empty.textContent = '{toc_empty_js}';
		    tocList.appendChild(empty);
		    return;
		  }}
		  headings.forEach(function(h) {{
		    var item = document.createElement('a');
		    item.className = 'toc-item l' + h.tagName.charAt(1);
		    item.href = '#' + h.id;
		    item.textContent = h.textContent;
		    item.addEventListener('click', function(e) {{
		      e.preventDefault();
		      h.scrollIntoView({{ behavior: 'smooth', block: 'start' }});
		      setTocActive(item);
		    }});
		    tocList.appendChild(item);
		  }});
		  updateTocScroll();
		}}
		window.__mdPreviewBuildToc = buildToc;
		function setTocActive(item) {{
		  var prev = tocList.querySelector('.toc-item.active');
		  if (prev) prev.classList.remove('active');
		  if (item) item.classList.add('active');
		}}
		function updateTocScroll() {{
		  var items = tocList.querySelectorAll('.toc-item');
		  if (!items.length) return;
		  var headings = document.querySelectorAll('#preview h1[id],#preview h2[id],#preview h3[id],#preview h4[id]');
		  var best = null;
		  headings.forEach(function(h, i) {{
		    if (h.getBoundingClientRect().top <= 96) best = items[i];
		  }});
		  setTocActive(best);
		}}
		window.addEventListener('scroll', function() {{
		  if (document.body.classList.contains('toc-hidden')) return;
		  clearTimeout(tocScrollTimer);
		  tocScrollTimer = setTimeout(updateTocScroll, 80);
		}}, {{ passive: true }});
		btnToc.innerHTML = ICON_LIST;
		if (btnToc) btnToc.addEventListener('click', function() {{
		  var hidden = document.body.classList.toggle('toc-hidden');
		  btnToc.classList.toggle('on', !hidden);
		  if (window.ipc) window.ipc.postMessage('toc-state:' + (hidden ? '0' : '1'));
		}});
```

- [ ] **Step 8: 挂重建钩子**

`window.__setContent` 内 `window.__setPreview(previewHtml, needsMath, needsMermaid);` 行后加:

```javascript
	    if (window.__mdPreviewBuildToc) window.__mdPreviewBuildToc();
```

`window.__setEmptyPreview` 和 `window.__setMissing` 内 `document.getElementById('preview').innerHTML = previewHtml;` 行后各加同一行:

```javascript
	    if (window.__mdPreviewBuildToc) window.__mdPreviewBuildToc();
```

模板尾部 (IIFE 外):

```html
{preview_enhance_js}
if(window.__enhancePreview)window.__enhancePreview();
```

改为:

```html
{preview_enhance_js}
if(window.__enhancePreview)window.__enhancePreview();
if(window.__mdPreviewBuildToc)window.__mdPreviewBuildToc();
```

- [ ] **Step 9: 加 format args**

`build_page` 末尾 format 参数块, `btn_zoom_in = s.btn_zoom_in,` 后加:

```rust
        btn_toc = s.btn_toc,
        toc_empty_js = escape_js(s.toc_empty),
```

- [ ] **Step 10: 修 5 处测试调用点 + 加模板测试**

现有测试里 `build_page(...)` 调用 (共 5 处, 传 6 参) 每处末尾的空状态参数后补 `true` (toc_open, 默认开)。两形态:

```rust
            &strings,
            true,
        );
```

和

```rust
            &strings,
            false,
        );
```

都变成 7 参 (末尾加 `true,`)。漏掉的站点 `cargo test` 会报 E0061 并给出位置, 逐个补齐。

tests 模块加:

```rust
    #[test]
    fn page_has_sidebar_toc_and_honors_toc_open_state() {
        let strings = Strings::for_lang(Lang::En);
        let open = build_page(
            &md_to_html("# Hello"),
            "# Hello",
            None,
            EnhanceFlags::default(),
            &strings,
            false,
            true,
        );
        assert!(open.contains("id=\"toc-sidebar\""));
        assert!(open.contains("id=\"btn-toc\""));
        assert!(open.contains("window.__mdPreviewBuildToc"));
        assert!(open.contains("toc-state:"));
        assert!(!open.contains("toc-hidden"));

        let closed = build_page(
            &md_to_html("# Hello"),
            "# Hello",
            None,
            EnhanceFlags::default(),
            &strings,
            false,
            false,
        );
        assert!(closed.contains("body class=\"toc-hidden\""));
    }
```

- [ ] **Step 11: 跑测试**

Run: `cargo test`
Expected: PASS 36 passed。若 E0061 → 回到 Step 10 补调用点。

- [ ] **Step 12: Commit**

```bash
git add src/main.rs
git commit -m "feat: sidebar TOC template, css, js and toggle button"
```

---

### Task 3: main() 接线 + IPC 持久化 + 验证 + release

**Files:**
- Modify: `D:\project\md_read\md-preview\src\main.rs` (main() 读状态传给 build_page 5 处调用点; IPC handler 加 `toc-state:` 分支)

**Interfaces:**
- Consumes: Task 1 的 `load_toc_open()` / `save_toc_open()`; Task 2 的 7 参 `build_page`。

- [ ] **Step 1: main() 读状态**

main() 中 `initial_page` 构建前 (找 `let initial_page = match` 前面) 加:

```rust
    let toc_open = load_toc_open();
```

- [ ] **Step 2: 5 处 build_page 调用补第 7 参**

initial_page 的 match 内 5 处 `build_page(` 调用 (特征: 传 `&strings,` + `false,`/`true,` 后 `)` 收尾) 每处末尾加 `toc_open,`。编译错 E0061 会列出遗漏位置, 逐个补齐。

- [ ] **Step 3: IPC handler 加分支**

找 `} else if body == "dirty:0" {` 行, 其后加:

```rust
            } else if let Some(state) = body.strip_prefix("toc-state:") {
                save_toc_open(state.trim() != "0");
```

- [ ] **Step 4: 跑测试**

Run: `cargo test`
Expected: PASS 36 passed

- [ ] **Step 5: debug 手动验证**

先杀残留 WebView2 防卡: `taskkill //F //IM msedgewebview2.exe`

Run: `cargo build && target/debug/md-preview.exe "D:\project\md_read\金砖赛人工智能赛项课程-离线版\01-情感计算之人脸表情识别\01-基础知识\情感计算之人脸表情识别-基础知识.md"`

Expected: 左侧出现目录, 多级缩进; 点击条目平滑滚动 + 高亮; 滚动正文当前章节高亮跟随; 点工具栏目录按钮侧边栏收起, 再点恢复; 关 app 重开, 开关状态保留 (toc-open.txt)。

- [ ] **Step 6: Commit**

```bash
git add src/main.rs
git commit -m "feat: wire toc open state into startup and persist via ipc"
```

- [ ] **Step 7: release 构建 + 验证 + 复制 exe**

```bash
cargo build --release
taskkill //F //IM msedgewebview2.exe
MD_PREVIEW_BENCH=1 ./target/release/md-preview.exe "D:\project\md_read\金砖赛人工智能赛项课程-离线版\03-具身智能平台部署与运维\03-实操手册\具身智能平台部署与运维-实操手册.md"
```

Expected: bench 输出 `ready` 后 exit 0 (超大文档 deferred 渲染路径 TOC 仍建)。

再普通启动一次确认不闪退、无 panic 日志 (`<exe目录>\md-preview.log` 不应存在), 然后:

```bash
cp target/release/md-preview.exe /d/project/md_read/MD-Preview-windows-x64.exe
```

(若提示 Device or resource busy: 先 `taskkill //F //IM MD-Preview-windows-x64.exe`。)

- [ ] **Step 8: 收尾**

`git status` 确认只有预期改动。若用户要上游 PR, 提醒 spec/plan 文档与主仓库无关, 单独提交。

---

## Self-Review Notes (已自查)

- Spec 覆盖: 布局/内容/重建时机/点击/scrollspy/持久化/打印/错误处理/测试 — Task 2 Step 4-8 覆盖模板全部, Task 3 覆盖接线与持久化, Task 1 覆盖默认值。空提示 `toc-empty` 在 buildToc 内。
- 类型一致: `toc_open: bool` 贯穿 Task 2/3; `window.__mdPreviewBuildToc` 在 Task 2 Step 7 定义、Step 8 调用; `toc-state:` 由 Step 7 发出、Task 3 Step 3 接收。
- 无占位符: 所有代码块完整。
