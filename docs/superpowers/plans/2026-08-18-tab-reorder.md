# 标签页拖拽排序 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 标签栏标签可拖拽重排, 松手落位, 新顺序写回会话持久化, 重启保持。

**Architecture:** HTML5 drag & drop 在前端重排 DOM (无重建无闪烁), drop 发一次 `tab-move:<from>:<to>` IPC; Rust 解析后发 `UserEvent::MoveTab`, 事件循环里 `DocumentSession::move_tab` + `persist_session`。索引语义: `from`/`to` 为会话 Vec (即 DOM) 索引, Rust 执行 `remove(from)` + `insert(to)`, 与前端 DOM 移动的最终序一致。

**Tech Stack:** Rust + wry/tao。`src/session.rs` (会话模块) + `src/main.rs` (模板 JS/CSS、IPC、事件)。无新依赖。

## Global Constraints

- IPC 格式: `tab-move:<from>:<to>` (两非负整数, 冒号分隔); 非法负载 (非数字、缺段) → 忽略; `from == to` → no-op 不发 IPC (前端守卫) 且 Rust 拒绝。
- 移动语义: `remove(from)` + `insert(to)`; `from`/`to` 越界 → 拒绝且不改变会话。
- 移动后**不重建标签 DOM** (前端已重排); 仅 `persist_session`。
- 活动标签不变 (移动不触碰 `active_id`)。
- 单标签/拖回原位 = no-op。
- 拖拽取消 (dragend 无 drop) → 仅清指示条, 无 IPC, DOM 无变化。
- 指示条明暗主题各配色。
- 现有 38 个测试保持通过。
- 前端只发合法负载: JS 已算好的 `from`/`to` 索引, 不做二次校验 (Rust 越界拒绝兜底)。

---

### Task 1: `DocumentSession::move_tab` + 单测

**Files:**
- Modify: `src/session.rs` (方法 + tests mod)
- 注意: 工作树中 `src/session.rs` 是干净的 (范围外改动只在 main.rs + update-check.js), **无需 stash 隔离** — 直接编辑、测试、提交。

**Interfaces:**
- Consumes: `DocumentSession` (现有字段 `tabs: Vec<DocumentTab>`, `active_id`), tests mod 的 `temp_dir` 辅助。
- Produces: `pub fn move_tab(&mut self, from: usize, to: usize) -> bool` — Task 2 事件循环调用。

- [ ] **Step 1: 写失败测试**

在 `src/session.rs` tests mod 的 `persisted_session_keeps_missing_tabs_and_active_order` 旁添加:

```rust
    #[test]
    fn moving_a_tab_reorders_without_touching_active() {
        let dir = temp_dir("move");
        let mut session = DocumentSession::default();
        let first = session.open(dir.join("one.md"), false);
        let second = session.open(dir.join("two.md"), false);
        let third = session.open(dir.join("three.md"), false);
        assert_eq!(session.active_id, Some(third));

        // [first, second, third] -> [second, third, first]
        assert!(session.move_tab(0, 2));
        assert_eq!(
            session.tabs.iter().map(|tab| tab.id).collect::<Vec<_>>(),
            vec![second, third, first]
        );
        assert_eq!(session.active_id, Some(third));

        // [second, third, first] -> [first, second, third]
        assert!(session.move_tab(2, 0));
        assert_eq!(
            session.tabs.iter().map(|tab| tab.id).collect::<Vec<_>>(),
            vec![first, second, third]
        );

        // no-op and out-of-bounds are rejected without change
        assert!(!session.move_tab(1, 1));
        assert!(!session.move_tab(0, 5));
        assert!(!session.move_tab(9, 0));
        assert_eq!(session.tabs.len(), 3);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn moved_order_roundtrips_through_save_and_load() {
        let dir = temp_dir("move-roundtrip");
        let state_path = dir.join("session.json");
        let one = dir.join("one.md");
        let two = dir.join("two.md");
        fs::write(&one, "# One").unwrap();
        fs::write(&two, "# Two").unwrap();
        let mut session = DocumentSession::default();
        session.open(one.clone(), false);
        session.open(two.clone(), false);

        assert!(session.move_tab(1, 0));

        session.save(&state_path).unwrap();
        let restored = DocumentSession::load(&state_path);
        assert_eq!(restored.tabs.len(), 2);
        assert_eq!(restored.tabs[0].path, fs::canonicalize(two).unwrap());
        assert_eq!(restored.tabs[1].path, fs::canonicalize(one).unwrap());
        let _ = fs::remove_dir_all(dir);
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test moving_a_tab` (Windows: 先 `export PATH="$PATH:/c/Users/kduo8/.cargo/bin"`)
Expected: 编译失败 — `move_tab` 方法不存在 (E0599)。Rust 中编译失败即 RED。

- [ ] **Step 3: 实现**

在 `close` 方法之后、`save` 之前加:

```rust
    pub fn move_tab(&mut self, from: usize, to: usize) -> bool {
        if from == to || from >= self.tabs.len() || to >= self.tabs.len() {
            return false;
        }
        let tab = self.tabs.remove(from);
        self.tabs.insert(to, tab);
        true
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (现有 38 + 新 2 = 40 passed)。

- [ ] **Step 5: 提交**

```bash
git add src/session.rs
git commit -m "feat: DocumentSession move_tab for tab reordering"
```

Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

### Task 2: IPC 解析 + UserEvent::MoveTab + 事件循环处理

**Files:**
- Modify: `src/main.rs` (解析辅助 fn + 单测; `UserEvent` 枚举 + `MoveTab(usize, usize)` 变体; IPC 分支; 事件循环 arm)

**Interfaces:**
- Consumes: `DocumentSession::move_tab` (Task 1), `persist_session(&DocumentSession)`, `session_for_ipc` (Arc<Mutex<DocumentSession>>), `proxy_for_ipc`, `UserEvent` 枚举。
- Produces: `fn parse_tab_move(body: &str) -> Option<(usize, usize)>`; `UserEvent::MoveTab(usize, usize)`; Task 3 前端发送的消息格式由本任务 IPC 分支确定。

- [ ] **Step 1: 写失败测试**

在 main.rs tests mod (toc 测试旁) 添加:

```rust
#[test]
fn tab_move_payload_parses_or_is_rejected() {
    assert_eq!(parse_tab_move("tab-move:0:2"), Some((0, 2)));
    assert_eq!(parse_tab_move("tab-move:10:0"), Some((10, 0)));
    assert_eq!(parse_tab_move("tab-move:abc:1"), None);
    assert_eq!(parse_tab_move("tab-move:0"), None);
    assert_eq!(parse_tab_move("tab-move:0:1:2"), None);
    assert_eq!(parse_tab_move("tab-action:activate:3"), None);
    assert_eq!(parse_tab_move("tab-move:"), None);
}
```

注意: `"tab-move:0:1:2"` 要求 None — 解析用 `split_once` 后 `to` 段含冒号 → parse::<usize> 失败 → None ✅ (代码见下)。

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test tab_move_payload`
Expected: 编译失败 — `parse_tab_move` 不存在。RED。

- [ ] **Step 3: 实现**

**a) 解析辅助 fn** (放 `apply_toc_width_payload` 旁):

```rust
fn parse_tab_move(body: &str) -> Option<(usize, usize)> {
    let rest = body.strip_prefix("tab-move:")?;
    let (from, to) = rest.split_once(':')?;
    Some((from.parse().ok()?, to.parse().ok()?))
}
```

**b) UserEvent 枚举** 加变体 (放 `CloseTab(u64),` 后):

```rust
    MoveTab(usize, usize),
```

**c) IPC 分支** (在 `tab-action:` 分支之前或之后, 保持现有分支顺序即可):

```rust
            } else if let Some((from, to)) = parse_tab_move(body) {
                let _ = proxy_for_ipc.send_event(UserEvent::MoveTab(from, to));
```

注意: `body` 类型为 `&String`, 直接传给 `parse_tab_move(body)` (deref 自动)。现有分支都用了 `body.strip_prefix(...)`, 本分支用辅助 fn 包装, 风格一致。

**d) 事件循环 arm** (放 `TaoEvent::UserEvent(UserEvent::CloseTab(id)) =>` arm 之后):

```rust
            TaoEvent::UserEvent(UserEvent::MoveTab(from, to)) => {
                let session = &mut *session_for_event.lock().unwrap();
                if session.move_tab(from, to) {
                    persist_session(session);
                }
            }
```

不调 `update_tabs` — 前端已重排 DOM, 重建会闪烁 (Global Constraints)。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (41 passed)。

- [ ] **Step 5: 提交 (stash 隔离)**

main.rs 工作树有范围外未提交改动。隔离手法 (与既往任务相同):

```bash
git stash push -- src/main.rs
git restore assets/enhance/update-check.js
# 测试
git add src/main.rs
git commit -m "feat: tab-move IPC parse and event handling"
git stash pop
rm assets/enhance/update-check.js
```

冲突保留双方 (新代码 + 范围外改动都存活)。验证 `grep -c "<<<<<<<" src/main.rs` → 0, `cargo test` 全绿。

Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

### Task 3: 前端拖拽 + 指示条 + 模板断言

**Files:**
- Modify: `src/main.rs` (模板: `__setTabs` 加 `draggable` 属性; 拖拽 JS; 指示条 CSS 明暗两套; 模板测试)

**Interfaces:**
- Consumes: IPC `tab-move:<from>:<to>` (Task 2 已接); `#tabs`/`tabsEl`、`.tab` 元素 (现有 `__setTabs` 渲染)。
- Produces: 完整拖拽交互。

**插入索引算法 (JS 与 Rust 语义一致的关键):** 设 `n = tabsEl.children.length`。拖拽悬停时算 `k` = 指针左侧「未被拖标签」的个数取 min 边界 (代码见下): 即 `k` 是被拖标签移除后的插入索引。drop 时 `tab.remove()` 后 `insertBefore(tab, children[k] || null)`。发 IPC `from`/`to` 用原始 `dragFrom` 与 `k` — Rust `remove(from)`+`insert(to)` 恰好产生同一最终序 (Task 1 测试已钉死语义)。

- [ ] **Step 1: 写失败测试**

在模板测试区添加 (build_page 调用模式复制现有测试, 如 `page_has_toc_width_drag_support`):

```rust
#[test]
fn page_has_tab_drag_reorder_support() {
    let s = Strings::zh_cn();
    let open = build_page("doc.md", &[], &s, true, None, true, true, 232);
    assert!(open.contains("draggable"));
    assert!(open.contains("'tab-move:'"));
    assert!(open.contains("drop-before"));
    assert!(open.contains("drop-after"));
    assert!(open.contains("dragstart"));
    assert!(open.contains("dragend"));
    assert!(open.contains("insertBefore"));
}
```

(若 build_page 实际签名不同, 复制现有测试的调用并保持参数。)

- [ ] **Step 3 前先跑 (Step 2): 确认失败**

Run: `cargo test page_has_tab_drag_reorder_support`
Expected: FAIL — 断言不满足 (draggable/拖拽 JS 不存在)。

- [ ] **Step 3: 实现**

**a) `__setTabs` 加 draggable**: 在 `item.setAttribute('data-tab-id', tab.id);` 后加:

```js
	    item.setAttribute('draggable', 'true');
```

**b) 拖拽 JS** (放 `__setTabs` 定义之后、keydown 监听之前或之后均可, 必须与 `tabsEl` 同一作用域):

```js
	var dragFrom = -1, dropTo = -1;
	tabsEl.addEventListener('dragstart', function(e) {{
	  var tab = e.target && e.target.closest ? e.target.closest('[data-tab-id]') : null;
	  if (!tab) {{ e.preventDefault(); return; }}
	  dragFrom = Array.prototype.indexOf.call(tabsEl.children, tab);
	  e.dataTransfer.effectAllowed = 'move';
	  try {{ e.dataTransfer.setData('text/plain', 'tab'); }} catch (err) {{}}
	}});
	tabsEl.addEventListener('dragover', function(e) {{
	  if (dragFrom < 0) return;
	  e.preventDefault();
	  e.dataTransfer.dropEffect = 'move';
	  var k = tabsEl.children.length - 1;
	  var removed = 0;
	  Array.prototype.forEach.call(tabsEl.children, function(tab, i) {{
	    if (i === dragFrom) {{ removed = 1; return; }}
	    var r = tab.getBoundingClientRect();
	    if (e.clientX < r.left + r.width / 2) k = Math.min(k, i - removed);
	  }});
	  dropTo = k;
	  var mark = (k >= dragFrom) ? k + 1 : k;
	  Array.prototype.forEach.call(tabsEl.children, function(tab, i) {{
	    tab.classList.toggle('drop-before', i === mark && mark < tabsEl.children.length);
	    tab.classList.toggle('drop-after', mark === tabsEl.children.length && i === tabsEl.children.length - 1);
	  }});
	}});
	tabsEl.addEventListener('drop', function(e) {{
	  if (dragFrom < 0 || dropTo < 0) return;
	  e.preventDefault();
	  var tab = tabsEl.children[dragFrom];
	  tab.remove();
	  var target = tabsEl.children[dropTo] || null;
	  tabsEl.insertBefore(tab, target);
	  var from = dragFrom, to = dropTo;
	  dragFrom = -1;
	  dropTo = -1;
	  Array.prototype.forEach.call(tabsEl.children, function(t) {{ t.classList.remove('drop-before', 'drop-after'); }});
	  if (from !== to) window.ipc.postMessage('tab-move:' + from + ':' + to);
	}});
	tabsEl.addEventListener('dragend', function() {{
	  dragFrom = -1;
	  dropTo = -1;
	  Array.prototype.forEach.call(tabsEl.children, function(t) {{ t.classList.remove('drop-before', 'drop-after'); }});
	}});
```

验证语义 (拖 A): [A,B,C] 拖到 C 之后 → k=2 → DOM [B,C,A], IPC `0:2` → Rust [B,C,A] ✅; 拖 C 到最前 → k=0 → [C,A,B], IPC `2:0` ✅; 拖 A 到 B/C 之间 → k=1 → [B,A,C], IPC `0:1` ✅; 原位放下 → from==to → 无 IPC ✅。

**c) 指示条 CSS** (明暗两套, 颜色取主题中现有强调色 — 亮色用与按钮一致的蓝, 暗色对应):

```css
	.tab.drop-before {{ box-shadow: inset 2px 0 0 #0b78d2; }}
	.tab.drop-after {{ box-shadow: inset -2px 0 0 #0b78d2; }}
```

(暗色块里替换颜色为暗色主题强调色; 若模板已有 CSS 变量强调色则用变量。)

注意: 模板是 `format!` 大字符串, JS/CSS 所有 `{`/`}` 双写 `{{`/`}}` (上文已按模板转义写好)。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (42 passed)。

- [ ] **Step 5: 提交 (stash 隔离)**

同 Task 2 手法。Commit:

```bash
git add src/main.rs
git commit -m "feat: drag to reorder tabs with drop indicator"
```

Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

## 自审记录

- Spec 覆盖: 拖拽交互 (Task 3)、持久化 (Task 2 事件 arm)、move 语义 (Task 1)、指示条 (Task 3)、取消清理 (Task 3 dragend)、no-op 守卫 (Task 1 + Task 3 from==to)、明暗主题 (Task 3)、错误处理 (Task 2 parse)。
- 占位符扫描: 无。
- 类型/命名一致性: `move_tab(from, to) -> bool` 三处一致; `parse_tab_move` → `Option<(usize, usize)>`; `UserEvent::MoveTab(usize, usize)`; JS `dragFrom`/`dropTo` 与 IPC `from`/`to` 语义一致 (Task 1 测试钉死)。
