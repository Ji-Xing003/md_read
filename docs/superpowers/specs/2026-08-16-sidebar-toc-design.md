# 侧边 TOC 导航设计

日期: 2026-08-16
状态: 已批准

## 目标

给预览加侧边目录大纲, 长课程文档可按标题导航。点击标题滚动到对应章节; 当前可见章节高亮。

## 不做的事

- 不做文件夹/文件树导航 (未来独立功能)。
- 侧边栏内不做标题搜索/过滤。
- 源码编辑模式不显示 TOC。

## 布局

- 左侧固定侧边栏, 约 240px 宽, 位于窗口边缘与预览区之间。侧边栏打开时预览区右移。
- 空状态 (没打开文档) 和源码编辑模式下隐藏。
- 悬浮工具栏 (右上角) 加 TOC 切换按钮。默认打开。
- 切换状态跨启动持久化, 存 `config_dir()/toc-open.txt` (`"1"` / `"0"`), 仿现有 `theme.txt` 模式。初始状态以 body class (`toc-hidden`) 注入页面。
- 打印输出不含侧边栏 (与其他应用界面元素同一机制)。

## TOC 内容

完全由前端 JS 从渲染后 DOM 构建:

- `buildToc()` 扫描 `#preview` 内带 `id` 的 `h1`–`h4` (pulldown-cmark 自动生成 id)。每项: 文本 = `heading.textContent`, 锚点 = `#id`, 按标题层级缩进。
- 重建时机:
  - 初始渲染 / enhance 流程后,
  - `__setContent` 后 (超大文档的 deferred 全量渲染、切换 tab、外部刷新、编辑),
  - 源码编辑保存并重新渲染后。
- 无标题文档显示本地化空提示 ("无标题" / "No headings")。
- 点击条目平滑滚动到对应标题 (`scrollIntoView`)。阻止默认行为, 不改 URL hash。
- scrollspy: `#preview` 滚动时 (节流), 高亮当前视口最顶部可见标题对应的条目。

前端收集理由: 标题 id 由 HTML 渲染器生成。Rust 侧再收集一次有 id 不匹配风险; DOM 在初始渲染、deferred 全量渲染、编辑流程中是唯一真源。

## Rust 改动

- 模板 (`build_page`):
  - 侧边栏容器 div + TOC 列表结构,
  - 明暗主题 CSS (侧边栏 + 条目),
  - `buildToc`、scrollspy、切换 JS,
  - 工具栏 TOC 切换按钮,
  - 钩子: 现有 `__setContent` 加 `buildToc()` 调用; enhance 流程触发 `buildToc()`。
- `Strings` 结构: 加 `btn_toc` 和 `toc_empty` 文案 (中/英), 用于切换按钮和空提示。
- 持久化: `toc_open_path()`, 放 `theme` 辅助函数旁; `main()` 读取, 关闭状态时注入 `toc-hidden` body class。
- IPC: 页面切换时发 `toc-state:1` / `toc-state:0`; 处理器写 `toc-open.txt` (仿现有写文件 IPC 分支)。
- 打印 CSS: 隐藏侧边栏。

## 错误处理

- `toc-open.txt` 缺失或损坏 → 默认打开 (与 theme 处理一致)。
- TOC 构建失败仅前端降级为空侧边栏, 无崩溃路径。

## 测试

- 模板断言: 侧边栏结构、切换按钮、`buildToc` JS 存在; 持久化状态为关闭时注入 `toc-hidden` class。
- 单元测试: `toc_open` 读写往返, 含文件缺失默认值。
- 现有 34 个测试保持通过。
- 手动: 打开课程 md (深层标题), 点击条目, 验证滚动 + 高亮, 关闭开关, 重启, 验证状态恢复。

## 涉及文件

- `src/main.rs` (模板、Strings、持久化、IPC、测试)
- 无新依赖。
