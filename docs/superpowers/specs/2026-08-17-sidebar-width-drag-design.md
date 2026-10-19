# 侧栏拖拽调宽设计

日期: 2026-08-17
状态: 已批准

## 目标

TOC 侧栏宽度可自定义: 鼠标拖拽侧栏右边缘调宽, 松开保存, 跨启动持久化。默认 232px (现值)。

## 不做的事

- 不做侧栏内其他元素拖拽/重排。
- 不做宽度档位预设按钮 (仅拖拽)。
- 不做拖拽以外的持久化入口 (配置文件手改不需要)。

## 布局与交互

- 侧栏右边缘加 6px 拖拽条 (`.toc-grip`), 悬停 `cursor: col-resize`, 带 tooltip (title)。
- 按住拖 → 实时改宽: JS 更新 CSS 变量 `--toc-width`, 立即生效, 无重绘闪烁。
- 松开 → IPC 发 `toc-width:<n>` → Rust 写配置文件。
- 范围 160–480px, 越界钳制 (加载时同样钳制)。
- 拖拽期间禁用文本选择: 拖拽条 `user-select: none`; 拖拽开始时 body 加 `user-select: none` (内联样式), 松开时移除。
- 侧栏隐藏 / 编辑模式 / 缺文件模式下无拖拽条 (侧栏整体 `display: none` 已覆盖)。

## CSS 变量化

- 宽度全部改用 `var(--toc-width)`, 值由 Rust 读取配置后在页面注入 (`:root` 内联样式, 仿 body class 注入)。
- 侧栏宽: `width: var(--toc-width)`; 预览区左移: `#app { padding-left: calc(var(--toc-width) + 18px); }` (18px = 侧栏与内容间距, 现值)。
- 该规则特异性不变 (1,3,1), 打印 `@media print` 的 `padding-left: 0 !important` 覆盖照旧有效。

## Rust 改动

- `toc_width_path()` = `config_dir()/toc-width.txt`; `load_toc_width() -> u32` (缺失/损坏 → 232, 越界钳制到 160–480); `save_toc_width(w: u32)`, 放 toc_open 辅助函数旁。
- `build_page` 加参数 `toc_width: u32`; 模板注入 `:root { --toc-width: <n>px; }`。
- IPC: 现有 `toc-state:` 分支旁加 `toc-width:<n>` 分支 → `save_toc_width`。
- 明暗主题: 拖拽条颜色各配一条。

## Strings

- 加 `toc_resize` 文案 (中/英): "拖拽调整宽度" / "Drag to resize", 用作拖拽条 title。

## 错误处理

- `toc-width.txt` 缺失或损坏 → 默认 232 (与 toc-open 处理一致)。
- IPC 收到非法数字 → 忽略 (不写文件)。
- 拖拽无崩溃路径 (纯前端 + 单次 IPC)。

## 测试

- 单元测试: `toc_width` 读写往返、文件缺失默认 232、越界值钳制 (如 "100" → 160, "9999" → 480)、非法 IPC 负载被忽略。
- 模板断言: `--toc-width` 注入、`calc(var(--toc-width) + 18px)` 存在、`.toc-grip` 存在、`toc-width:` IPC 字符串存在、持久化宽度值注入。
- 现有 36 个测试保持通过。
- 手动: 打开课程 md, 拖侧栏右缘, 验证实时变宽 + 松开后重启保持; 拖到边界验证钳制; 打印无左边距。

## 涉及文件

- `src/main.rs` (模板、Strings、持久化、IPC、测试)
- 无新依赖。
