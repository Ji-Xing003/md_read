# 内存占用压缩设计

日期: 2026-08-18
状态: 已批准

## 目标

降低 md-preview 启动后的内存占用。大头是 WebView2 渲染进程 (任务管理器显示 about:blank): 课程 md 内嵌的大 base64 图片解码后占满内存。双管齐下: 嵌入前压缩图片 (方案 1), 关闭 GPU 进程 (方案 2)。

## 方案 1: 图片嵌入前优化

钩子: `local_image_data_url` (src/main.rs:544) — 唯一的本地图片嵌入点。

**流程** (每个图片独立执行):

1. 读文件字节 (现状)。
2. 尝试 `image::load_from_memory` 解码。
3. 只优化以下格式: PNG、JPEG、BMP (2026-08-20 修订: 带 alpha 的 PNG 也优化, 见步骤 5b)。**跳过**: GIF (不损失动画)、ICO、SVG、webp、avif、带 EXIF 方向的 JPEG (重编码丢方向, 会旋转) 及一切解码失败者。
4. 最长边 > 1440px → 等比缩到 1440 (Lanczos3)。
5. 重编码:
   - a. 无 alpha: JPEG q85。**若结果 ≥ 原文件字节数 → 保留原样** (原 mime 原字节)。
   - b. 有 alpha: PNG 重编码 (保留透明)。**若结果 ≥ 原文件字节数 → 保留原样**。
6. 任何一步失败 → 原样嵌入 (现状兜底, 绝不破图)。

**阈值依据 (2026-08-20 修订)**: 解码位图内存只与像素数有关 (每像素 4B), 与文件格式无关 — 6400×4800 PNG 解码即 ~123MB。预览内容区 ~900 CSS px, 150% 显示缩放只需 ~1350px 位图, 故阈值 1920 → 1440。JPEG 转换只缩 HTML 字符串; 缩内存靠缩小尺寸, 故 alpha 图也必须缩 (回编码 PNG 保透明)。

**依赖**: Cargo.toml 的 image features 加 `"jpeg"` (解码 JPEG + 编码 JPEG)。png/ico 已有。

## 方案 2: 关闭 GPU 进程

WebViewBuilder (src/main.rs:4039) 加 `.with_additional_browser_args("--disable-gpu")`。

- 效果: WebView2 退回 CPU 软件渲染, GPU 进程消失 (~50–150MB)。静态文档 + 图片渲染无感。
- 无视频/WebGL/CSS 3D 场景, 无实际损失。
- 全平台加 (Windows 生效; WebKitGTK 忽略该参数, 无害)。

## 不做的事

- 不改 HTML 生成方式 (仍 base64 内嵌, 保持单文件可移植)。
- 不做图片懒加载/虚拟化。
- 不做渲染后字符串释放 (方案 3, 以后再说)。
- 不动 WebView2 浏览器主进程 (基线固定, 无压缩手段)。

## 错误处理

- 解码失败、编码失败、输出更大 → 全部回退原样嵌入。图片加载路径行为与现在完全一致。
- 新依赖 feature 编译失败 → 构建期即暴露 (无运行时风险)。

## 测试

- `local_image_data_url` 直接单测 (temp 目录 + 测试生成图片):
  - 大无透明 PNG (如 1200×800 纯色+噪点) → 返回 `image/jpeg` 且字节数 < 原文件。
  - 超宽 JPEG (如 2500×100) → 返回后解码验证最长边 ≤ 1440 (或断言结果更小; 具体断言以字节数缩小为主)。
  - 带 alpha PNG → 大尺寸 (如 2000×2000) 时缩到 1440 且 mime 仍 `image/png`; 小尺寸且重编码不更小 → 字节数不变 (未优化)。
  - 带 EXIF 方向的 JPEG → 不优化。
  - 坏字节文件 → None (现有回退路径)。
- 现有 38 个测试保持通过。
- 手动: 开课程 md, 任务管理器验证 (a) about:blank 渲染进程内存下降, (b) GPU 进程消失; 图片全部正常显示。

## 涉及文件

- `src/main.rs` (优化函数 + 测试; WebViewBuilder 参数)
- `Cargo.toml` (image features)
- 无新 crate。
