# 侧栏拖拽调宽 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TOC 侧栏宽度可由用户拖拽调整 (160–480px), 松开保存到 `toc-width.txt`, 跨启动持久化, 默认 232px。

**Architecture:** 宽度全部改用 CSS 变量 `--toc-width`, Rust 启动时读取配置注入页面 (`:root` 内联样式); 前端拖拽条 (pointer events) 实时更新变量, 松开发 `toc-width:<n>` IPC 给 Rust 写文件。现有打印 `!important` 覆盖机制不变。

**Tech Stack:** Rust + wry/tao, 全部改动在 `src/main.rs`, 无新依赖。

## Global Constraints

- 宽度范围: 160–480px (越界钳制, 加载时同样钳制)。
- 默认宽度: 232px。
- 侧栏与内容间距: 18px, 即 `#app { padding-left: calc(var(--toc-width) + 18px); }`。
- 持久化文件: `config_dir()/toc-width.txt`, 存纯数字 px。缺失/损坏 → 232。
- IPC 格式: `toc-width:<n>` (无空格, n 为非负整数)。非法负载忽略, 不写文件。
- 新文案键 `toc_resize`: 中文 "拖拽调整宽度", 英文 "Drag to resize"。
- 打印 `@media print` 的 `#app { padding-left: 0 !important; ... }` 必须继续覆盖预览 padding (calc 规则特异性与原规则相同, 不得引入更高特异性的选择器)。
- 拖拽期间禁用文本选择: 拖拽条 `user-select: none`; 拖拽开始时 body 内联 `user-select: none`, 松开移除。
- 现有 36 个测试保持通过 (TOC 侧栏相关测试含 print 断言)。
- 每次构建页面时读取当前宽度 (`load_toc_width()`), 因宽度在会话内可被拖拽改变, 后续重建必须用新值 — 不要只读一次缓存。

---

### Task 1: Rust 宽度持久化 + 页面注入

**Files:**
- Modify: `src/main.rs` (toc_open 辅助函数旁加宽度辅助; `build_page` 签名 + 模板 `:root` 注入 + format args; 所有 `build_page` 调用点; IPC 分支; 测试)

**Interfaces:**
- Consumes: `config_dir()`, `temp_test_dir()` (tests mod 已有), `build_page` 现有 7 参签名。
- Produces:
  - `fn toc_width_path() -> PathBuf` — `config_dir().join("toc-width.txt")`
  - `fn load_toc_width() -> u32` — 缺失/损坏 → 232; 越界钳制 160–480
  - `fn save_toc_width(width: u32)`
  - `fn apply_toc_width_payload(body: &str) -> bool` — 解析 `toc-width:<n>`, 成功保存返回 true, 否则 false (不写文件)
  - `build_page(..., toc_width: u32)` 第 8 参数; 模板注入 `:root {{ --toc-width: {toc_width}px; }}` (format 参数名 `toc_width`)

- [ ] **Step 1: 写失败测试**

在 tests mod 的 toc 测试旁添加 (注意 env 全局覆盖的既有约定 — 本二进制内无其他测试在运行时读 config_dir, 加同样注释):

```rust
#[test]
fn toc_width_defaults_clamps_and_roundtrips() {
    // No other test in this binary reads config_dir at runtime, so the
    // process-wide env override is safe here (and keeps the test off the
    // real user config dir).
    let dir = temp_test_dir("toc-width");
    std::env::set_var("MD_PREVIEW_CONFIG_DIR", dir.to_string_lossy().into_owned());

    assert_eq!(load_toc_width(), 232); // missing file -> default

    let path = toc_width_path();
    fs::write(&path, "100").unwrap();
    assert_eq!(load_toc_width(), 160); // below min -> clamped
    fs::write(&path, "9999").unwrap();
    assert_eq!(load_toc_width(), 480); // above max -> clamped
    fs::write(&path, "not-a-number").unwrap();
    assert_eq!(load_toc_width(), 232); // corrupt -> default

    save_toc_width(300);
    assert_eq!(load_toc_width(), 300); // roundtrip

    // invalid IPC payloads are ignored and do not touch the file
    let before = fs::read_to_string(&path).unwrap();
    assert!(!apply_toc_width_payload("toc-width:abc"));
    assert!(!apply_toc_width_payload("toc-state:1"));
    assert_eq!(fs::read_to_string(&path).unwrap(), before);

    std::env::remove_var("MD_PREVIEW_CONFIG_DIR");
    let _ = fs::remove_dir_all(dir);
}
```

再在模板测试 `page_has_sidebar_toc_and_honors_toc_open_state` 末尾加两行 (build_page 调用处加第 8 参 `232`):

```rust
assert!(open.contains("--toc-width: 232px"));
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test` (Windows: 先 `export PATH="$PATH:/c/Users/kduo8/.cargo/bin"`)
Expected: 编译失败 — `load_toc_width`、`toc_width_path`、`save_toc_width`、`apply_toc_width_payload` 未找到; `build_page` 第 8 参缺失 (E0061)。Rust 中编译失败即 RED。

- [ ] **Step 3: 实现**

toc_open 辅助函数旁添加:

```rust
fn toc_width_path() -> PathBuf {
    config_dir().join("toc-width.txt")
}

fn load_toc_width() -> u32 {
    const DEFAULT: u32 = 232;
    const MIN: u32 = 160;
    const MAX: u32 = 480;
    fs::read_to_string(toc_width_path())
        .ok()
        .and_then(|raw| raw.trim().parse::<u32>().ok())
        .map(|w| w.clamp(MIN, MAX))
        .unwrap_or(DEFAULT)
}

fn save_toc_width(width: u32) {
    let dir = config_dir();
    let _ = fs::create_dir_all(&dir);
    let _ = fs::write(dir.join("toc-width.txt"), width.to_string());
}

fn apply_toc_width_payload(body: &str) -> bool {
    if let Some(raw) = body.strip_prefix("toc-width:") {
        if let Ok(w) = raw.trim().parse::<u32>() {
            save_toc_width(w);
            return true;
        }
    }
    false
}
```

`build_page` 签名加第 8 参 `toc_width: u32`。模板: 在 `<head>` 里主题 CSS 之后 (或在注入 body class 附近) 加一行:

```html
<style>:root {{ --toc-width: {toc_width}px; }}</style>
```

format 调用加 `toc_width = toc_width,`。

`main`/事件处理里所有 `build_page(...)` 调用点 (生产 5 处 + 测试 2 处) 加第 8 参。生产调用点传 `load_toc_width()` (见 Global Constraints — 每建页读当前值, 不缓存); 测试调用点传字面量 (如 `232`)。

IPC: 现有 `toc-state:` 分支旁加:

```rust
} else if body.starts_with("toc-width:") {
    apply_toc_width_payload(body);
```

(返回值忽略 — 保存失败无需反馈。)

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (37 passed — 原 36 + 新 1)。

- [ ] **Step 5: 提交**

```bash
git add src/main.rs
git commit -m "feat: toc width persistence and page injection"
```

Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

**实现隔离 (重要):** 工作树有范围外未提交改动 (自更新移除 + panic 日志 + 2MB 修复)。提交前用 stash 隔离:
`git stash push -- src/main.rs` → 测试/`git add src/main.rs` → commit → `git stash pop` → 解决冲突保留双方 (本任务新代码 + 范围外改动都要存活) → 验证 `grep -c "<<<<<<<" src/main.rs` 为 0、`cargo test` 仍全绿。注意 `assets/enhance/update-check.js` 已被范围外删除 — 隔离态下 HEAD main.rs 的 `include_str!` 引用它, 需临时 `git restore` 回来才能编译, 提交后 `rm` 删掉 (与上次 fix 提交相同手法)。

---

### Task 2: 拖拽条 UI + 前端拖拽逻辑

**Files:**
- Modify: `src/main.rs` (Strings 加 `toc_resize`; CSS: 侧栏宽变量化 + 拖拽条样式明暗两套; HTML: grip 元素; JS: pointer 拖拽; 测试)

**Interfaces:**
- Consumes: `--toc-width` 变量注入 (Task 1), `build_page` 第 8 参。
- Produces: 完整拖拽交互; 最终宽度经 IPC `toc-width:<n>` 持久化 (Task 1 已实现接收)。

- [ ] **Step 1: 写失败测试**

新模板测试:

```rust
#[test]
fn page_has_toc_width_drag_support() {
    let s = Strings::zh_cn();
    let open = build_page("doc.md", &[], &s, true, None, true, true, 232);
    assert!(open.contains("id=\"toc-grip\""));
    assert!(open.contains("calc(var(--toc-width) + 18px)"));
    assert!(open.contains("width: var(--toc-width)"));
    assert!(open.contains("'toc-width:'"));
    assert!(open.contains("userSelect"));
    assert!(open.contains("拖拽调整宽度"));
    // print override must keep winning over the calc rule
    assert!(open.contains("padding-left: 0 !important"));
}
```

(若现有 `build_page` 测试调用的参数与本处不同, 以实际签名为准复制调用模式。)

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test page_has_toc_width_drag_support`
Expected: FAIL — 断言不满足 (grip/calc/JS 均不存在)。

- [ ] **Step 3: 实现**

**Strings**: 结构体加 `toc_resize: &'static str`; 中文表 `"拖拽调整宽度"`, 英文表 `"Drag to resize"` (两个构造函数都补)。

**CSS (明暗两套)**:

- `.toc-sidebar` 现有 `width: 232px` → `width: var(--toc-width);`
- 预览 padding 规则 (含 `.missing` 排除的那条): `padding-left: 250px` → `padding-left: calc(var(--toc-width) + 18px);` — 选择器一字不改 (特异性不变, 打印 `!important` 覆盖仍有效)。
- 拖拽条 (亮色示例, 暗色按主题配色对应替换):

```css
.toc-grip {{
  position: absolute;
  top: 0; right: 0; bottom: 0;
  width: 6px;
  cursor: col-resize;
  user-select: none;
  -webkit-user-select: none;
  background: transparent;
}}
.toc-grip:hover, .toc-grip:active {{ background: rgba(0, 120, 212, 0.35); }}
```

`.toc-sidebar` 是 `position: fixed`, absolute 子元素相对它定位, 无需额外定位容器。`.toc-item` 若右缘文字被 grip 覆盖, 给 `.toc-item` 加 `padding-right: 12px`。

**HTML**: `.toc-sidebar` 内 `#toc-list` 之后加:

```html
<div class="toc-grip" id="toc-grip" title="{toc_resize}"></div>
```

format 参数 `toc_resize` 用现有 HTML 属性转义辅助函数 (与模板里其他 title/属性字符串一致 — 查现有用法, 通常是 `escape_html` 或等价物; 若属性字符串都直接插入, 保持一致)。`toc_resize_esc = ...,` 加入 format 调用。

**JS** (btnToc 处理附近, buildToc 定义之后):

```js
var tocGrip = document.getElementById('toc-grip');
if (tocGrip) {
  var tocDrag = null;
  tocGrip.addEventListener('pointerdown', function(e) {
    tocDrag = { startX: e.clientX, startW: tocGrip.parentElement.getBoundingClientRect().width, w: null };
    tocGrip.setPointerCapture(e.pointerId);
    document.body.style.userSelect = 'none';
    e.preventDefault();
  });
  tocGrip.addEventListener('pointermove', function(e) {
    if (!tocDrag) return;
    var w = Math.min(480, Math.max(160, Math.round(tocDrag.startW + (e.clientX - tocDrag.startX))));
    document.documentElement.style.setProperty('--toc-width', w + 'px');
    tocDrag.w = w;
  });
  function endTocDrag() {
    if (!tocDrag) return;
    document.body.style.userSelect = '';
    if (tocDrag.w !== null) window.ipc.postMessage('toc-width:' + tocDrag.w);
    tocDrag = null;
  }
  tocGrip.addEventListener('pointerup', endTocDrag);
  tocGrip.addEventListener('pointercancel', endTocDrag);
}
```

注意模板是 `format!` 大字符串: JS 里所有 `{`/`}` 都要双写 `{{`/`}}`。`'toc-width:'` 字符串出现即满足 Step 1 断言。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (38 passed)。

- [ ] **Step 5: 提交**

```bash
git add src/main.rs
git commit -m "feat: drag to resize toc sidebar"
```

Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

**实现隔离:** 同 Task 1 的 stash 手法。

---

## 自审记录

- Spec 覆盖: 拖拽 (Task 2)、持久化 + 钳制 (Task 1)、CSS 变量化 (Task 2)、IPC (Task 1)、tooltip 文案 (Task 2)、打印覆盖保持 (两任务测试断言)、禁选 (Task 2 JS)。
- 占位符扫描: 无。
- 类型/命名一致性: `load_toc_width`/`save_toc_width`/`apply_toc_width_payload` 在接口块与代码一致; format 参数名 `toc_width`; JS 变量 `--toc-width` 一致。
