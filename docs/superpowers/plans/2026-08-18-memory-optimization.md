# 内存占用压缩 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 降低启动后内存: 嵌入前压缩大图片 (无透明 PNG/JPEG/BMP → 缩放 + JPEG q85), 关 WebView2 GPU 进程。

**Architecture:** `local_image_data_url` 是唯一图片嵌入点 — 读字节后尝试优化, 更小才替换, 任何失败回退原样。`WebViewBuilder` 加 `--disable-gpu` 砍 GPU 进程。优化不改变 base64 内嵌架构, 单文件可移植性不变。

**Tech Stack:** Rust + wry/tao + image crate (加 jpeg feature)。`src/main.rs` + `Cargo.toml`。

## Global Constraints

- 最长边 > 1920px → 等比缩到 1920 (Lanczos3); JPEG 质量 85。
- 只优化: 无 alpha 的 PNG / JPEG / BMP (按 `image_mime_type` 返回的 mime 判断)。带 alpha PNG、GIF、ICO、SVG、webp、avif 及其他一律不动。
- **结果 ≥ 原文件字节数 → 保留原样** (原 mime 原字节)。
- 任何一步失败 → 原样嵌入 (绝不破图)。
- 常量: `EMBED_IMAGE_MAX_EDGE: u32 = 1920`, `EMBED_IMAGE_JPEG_QUALITY: u8 = 85`。不引入配置。
- `--disable-gpu` 加在现有 WebViewBuilder 链上, 不影响其他参数。
- 现有 38 个测试保持通过。

---

### Task 1: 图片嵌入前优化

**Files:**
- Modify: `Cargo.toml` (image features 加 `"jpeg"`)
- Modify: `src/main.rs` (`local_image_data_url`、新 `optimize_image_for_embed`、常量、tests mod 新测试)

**Interfaces:**
- Consumes: `local_image_data_url` (src/main.rs:544), `base64_encode`, `temp_test_dir` (tests mod), `image_mime_type` (扩展名判断)。
- Produces: `fn optimize_image_for_embed(original: &[u8], mime: &str) -> Option<Vec<u8>>` — 成功返回更小的 JPEG 字节; 不可优化/失败/不更小 → None (Task 1 内自消费, 无跨任务消费者)。

- [ ] **Step 1: 写失败测试**

在 tests mod (toc 测试旁) 添加:

```rust
#[test]
fn noisy_png_optimizes_to_smaller_jpeg() {
    let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(1200, 800, |x, y| {
        let mut v = (x as u64)
            .wrapping_mul(2654435761)
            .wrapping_add((y as u64).wrapping_mul(1597334677));
        v = (v ^ (v >> 13)).wrapping_mul(2246822519);
        v ^= v >> 16;
        image::Rgb([(v & 0xff) as u8, ((v >> 8) & 0xff) as u8, ((v >> 16) & 0xff) as u8])
    }));
    let mut png_bytes = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut png_bytes), image::ImageFormat::Png)
        .unwrap();

    let out = optimize_image_for_embed(&png_bytes, "image/png").unwrap();

    assert!(out.len() < png_bytes.len());
    assert_eq!(image::guess_format(&out).unwrap(), image::ImageFormat::Jpeg);
}

#[test]
fn oversized_image_is_resized_to_max_edge() {
    let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(2500, 100, |x, y| {
        image::Rgb([(x / 10 % 256) as u8, (y / 10 % 256) as u8, 128])
    }));
    let mut png_bytes = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut png_bytes), image::ImageFormat::Png)
        .unwrap();

    let out = optimize_image_for_embed(&png_bytes, "image/png").unwrap();
    let decoded = image::load_from_memory(&out).unwrap();

    assert_eq!(decoded.width(), 1920);
    assert_eq!(decoded.height(), 77); // 100 * 1920/2500 = 76.8 -> round 77
}

#[test]
fn alpha_png_and_unsupported_and_bad_bytes_are_not_optimized() {
    let alpha = image::DynamicImage::ImageRgba8(image::RgbaImage::from_fn(64, 64, |_, _| {
        image::Rgba([10, 20, 30, 40])
    }));
    let mut alpha_bytes = Vec::new();
    alpha
        .write_to(&mut std::io::Cursor::new(&mut alpha_bytes), image::ImageFormat::Png)
        .unwrap();
    assert!(optimize_image_for_embed(&alpha_bytes, "image/png").is_none());
    assert!(optimize_image_for_embed(&alpha_bytes, "image/gif").is_none());
    assert!(optimize_image_for_embed(b"not an image", "image/png").is_none());
}

#[test]
fn embedded_data_url_uses_jpeg_only_when_smaller() {
    let dir = temp_test_dir("img-embed");
    let noisy = image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(600, 400, |x, y| {
        let mut v = (x as u64)
            .wrapping_mul(2654435761)
            .wrapping_add((y as u64).wrapping_mul(1597334677));
        v = (v ^ (v >> 13)).wrapping_mul(2246822519);
        v ^= v >> 16;
        image::Rgb([(v & 0xff) as u8, ((v >> 8) & 0xff) as u8, ((v >> 16) & 0xff) as u8])
    }));
    noisy.save(dir.join("noisy.png")).unwrap();
    let alpha = image::DynamicImage::ImageRgba8(image::RgbaImage::from_fn(32, 32, |_, _| {
        image::Rgba([1, 2, 3, 4])
    }));
    alpha.save(dir.join("alpha.png")).unwrap();
    fs::write(dir.join("broken.png"), b"junk").unwrap();

    let noisy_url = local_image_data_url(&dir, "noisy.png").unwrap();
    assert!(noisy_url.starts_with("data:image/jpeg;base64,"));
    let noisy_payload = noisy_url.strip_prefix("data:image/jpeg;base64,").unwrap();
    assert!(noisy_payload.len() < fs::metadata(dir.join("noisy.png")).unwrap().len() as usize);

    let alpha_url = local_image_data_url(&dir, "alpha.png").unwrap();
    assert_eq!(
        alpha_url,
        format!(
            "data:image/png;base64,{}",
            base64_encode(&fs::read(dir.join("alpha.png")).unwrap())
        )
    );

    let broken_url = local_image_data_url(&dir, "broken.png").unwrap();
    assert_eq!(
        broken_url,
        format!(
            "data:image/png;base64,{}",
            base64_encode(&fs::read(dir.join("broken.png")).unwrap())
        )
    );
    let _ = fs::remove_dir_all(dir);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test noisy_png_optimizes` (先 `export PATH="$PATH:/c/Users/kduo8/.cargo/bin"`)
Expected: 编译失败 — `optimize_image_for_embed` 不存在。RED。(若 Cargo.toml 未加 jpeg 则先加 — 但 TDD 顺序: 让编译错误先出现, 再一起修。)

- [ ] **Step 3: 实现**

**a) Cargo.toml**:

```toml
image = { version = "0.25", default-features = false, features = ["png", "ico", "jpeg"] }
```

**b) main.rs** — `base64_encode` 上方加常量和函数:

```rust
const EMBED_IMAGE_MAX_EDGE: u32 = 1920;
const EMBED_IMAGE_JPEG_QUALITY: u8 = 85;

fn optimize_image_for_embed(original: &[u8], mime: &str) -> Option<Vec<u8>> {
    if !matches!(mime, "image/png" | "image/jpeg" | "image/bmp") {
        return None;
    }
    let img = image::load_from_memory(original).ok()?;
    if img.color().has_alpha() {
        return None;
    }
    let (w, h) = (img.width(), img.height());
    let img = if w.max(h) > EMBED_IMAGE_MAX_EDGE {
        let scale = EMBED_IMAGE_MAX_EDGE as f64 / w.max(h) as f64;
        let nw = ((w as f64 * scale).round() as u32).max(1);
        let nh = ((h as f64 * scale).round() as u32).max(1);
        img.resize(nw, nh, image::imageops::FilterType::Lanczos3)
    } else {
        img
    };
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, EMBED_IMAGE_JPEG_QUALITY)
        .encode_image(&img)
        .ok()?;
    Some(out)
}
```

注意 image 0.25 API: 若 `encode_image` 不存在 (旧版本), 用 `encoder.encode(&img.to_rgb8(), img.width(), img.height())` (按该版本实际签名 — 若要求 `&[u8]` 则传 `img.to_rgb8().as_raw()`); 以 `cargo doc`/编译错误为准, 语义不变。

**c) `local_image_data_url` 改造** (src/main.rs:544-549):

```rust
fn local_image_data_url(base_dir: &Path, url: &str) -> Option<String> {
    let image_path = resolve_local_relative_image_path(base_dir, url)?;
    let mime = image_mime_type(&image_path)?;
    let bytes = fs::read(image_path).ok()?;
    match optimize_image_for_embed(&bytes, mime) {
        Some(data) if data.len() < bytes.len() => {
            Some(format!("data:image/jpeg;base64,{}", base64_encode(&data)))
        }
        _ => Some(format!("data:{mime};base64,{}", base64_encode(&bytes))),
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (38 + 4 = 42 passed)。首次编译会拉 jpeg 编解码 (已在 image crate 内, 无新 crate, 无网络问题)。

- [ ] **Step 5: 提交 (stash 隔离)**

`src/main.rs` 有范围外未提交改动; `Cargo.toml` 干净。

```bash
git stash push -- src/main.rs
git restore assets/enhance/update-check.js
# 实现 + 测试 (Cargo.toml 直接改, 不 stash)
git add src/main.rs Cargo.toml
git commit -m "feat: compress oversized images before embed"
git stash pop
rm assets/enhance/update-check.js
```

冲突保留双方。验证 `grep -c "<<<<<<<" src/main.rs` → 0, `cargo test` 全绿。

Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

### Task 2: 关闭 WebView2 GPU 进程

**Files:**
- Modify: `src/main.rs` (WebViewBuilder 链, src/main.rs:4039 附近)

**Interfaces:**
- Consumes: `WebViewBuilder` (wry 0.50)。
- Produces: 无 (构建期配置)。

- [ ] **Step 1: 实现**

在 `.with_html(&initial_page)` 之前或之后 (链上任一位置) 加:

```rust
        .with_additional_browser_args("--disable-gpu")
```

- [ ] **Step 2: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (42 passed)。本改动无单测 (构建参数, 无法从模板/单元断言) — 手动验证: 启动后任务管理器无 GPU 进程。

- [ ] **Step 3: 提交 (stash 隔离)**

同 Task 1 手法:

```bash
git stash push -- src/main.rs
git restore assets/enhance/update-check.js
git add src/main.rs
git commit -m "feat: disable webview2 gpu process"
git stash pop
rm assets/enhance/update-check.js
```

冲突保留双方, 验证 markers 0 + 测试全绿。Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

### Task 3: 阈值降至 1440 + alpha PNG 缩放 (spec 修订 56f38b6)

**Files:**
- Modify: `src/main.rs` (`optimize_image_for_embed`、`EMBED_IMAGE_MAX_EDGE`、tests mod)

**Interfaces:**
- Consumes: `optimize_image_for_embed` (Task 1 现状: 无 alpha 白名单 + JPEG 路径 + EXIF 方向跳过, commit e90cb87 后)。
- Produces: 修订后的 `optimize_image_for_embed` — alpha PNG 也缩放回编码 PNG; 阈值 1440。

- [ ] **Step 1: 写失败测试**

在现有 4 个图片测试旁添加:

```rust
#[test]
fn oversized_alpha_png_is_resized_and_kept_png() {
    let img = image::DynamicImage::ImageRgba8(image::RgbaImage::from_fn(2000, 2000, |x, y| {
        let mut v = (x as u64)
            .wrapping_mul(2654435761)
            .wrapping_add((y as u64).wrapping_mul(1597334677));
        v = (v ^ (v >> 13)).wrapping_mul(2246822519);
        v ^= v >> 16;
        image::Rgba([(v & 0xff) as u8, ((v >> 8) & 0xff) as u8, ((v >> 16) & 0xff) as u8, 255])
    }));
    let mut png_bytes = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut png_bytes), image::ImageFormat::Png)
        .unwrap();

    let out = optimize_image_for_embed(&png_bytes, "image/png").unwrap();

    assert!(out.len() < png_bytes.len());
    assert_eq!(image::guess_format(&out).unwrap(), image::ImageFormat::Png);
    let decoded = image::load_from_memory(&out).unwrap();
    assert_eq!(decoded.width(), 1440);
    assert_eq!(decoded.height(), 1440);
    assert!(decoded.color().has_alpha());
}
```

同时把 `oversized_image_is_resized_to_max_edge` 中 2500×100 的断言改为: `decoded.width() == 1440`, `decoded.height() == 58` (100 × 1440/2500 = 57.6 → round 58)。

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test oversized_alpha`
Expected: FAIL — `optimize_image_for_embed` 对 alpha 图返回 None (断言 unwrap 失败), 且旧测试的 1920 断言失败。RED。

- [ ] **Step 3: 实现**

`EMBED_IMAGE_MAX_EDGE` 改为 1440。`optimize_image_for_embed` 重写:

```rust
const EMBED_IMAGE_MAX_EDGE: u32 = 1440;
const EMBED_IMAGE_JPEG_QUALITY: u8 = 85;

fn optimize_image_for_embed(original: &[u8], mime: &str) -> Option<Vec<u8>> {
    if !matches!(mime, "image/png" | "image/jpeg" | "image/bmp") {
        return None;
    }
    if mime == "image/jpeg" {
        let orientation = image::codecs::jpeg::JpegDecoder::new(std::io::Cursor::new(original))
            .ok()?
            .orientation()
            .ok()?;
        if orientation != image::metadata::Orientation::NoTransforms {
            return None;
        }
    }
    let img = image::load_from_memory(original).ok()?;
    let (w, h) = (img.width(), img.height());
    let img = if w.max(h) > EMBED_IMAGE_MAX_EDGE {
        let scale = EMBED_IMAGE_MAX_EDGE as f64 / w.max(h) as f64;
        let nw = ((w as f64 * scale).round() as u32).max(1);
        let nh = ((h as f64 * scale).round() as u32).max(1);
        img.resize(nw, nh, image::imageops::FilterType::Lanczos3)
    } else {
        img
    };
    let mut out = Vec::new();
    if img.color().has_alpha() {
        // keep transparency: re-encode PNG
        img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
            .ok()?;
    } else {
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, EMBED_IMAGE_JPEG_QUALITY)
            .encode_image(&img)
            .ok()?;
    }
    Some(out)
}
```

(EXIF 方向检查与 encode_image 的实际 API 以 e90cb87 落地代码为准 — 保持它已验证的写法, 只按上面重组 alpha 分支和阈值。`image::metadata::Orientation` 是 e90cb87 验证过的路径。)

注意: `local_image_data_url` 的替换逻辑不变 — `Some(data) if data.len() < bytes.len()` → 用新编码 (PNG 分支 mime 仍是原 `image/png`; JPEG 分支 `image/jpeg`)。alpha PNG 优化后 mime 恰好不变, 现有 `data:{mime};base64` 分支自然正确。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test`
Expected: 全部通过 (43 + 1 新 = 44 passed; 旧测试的 1920 断言已改 1440)。

- [ ] **Step 5: 提交 (stash 隔离)**

同前手法:

```bash
git stash push -- src/main.rs
git restore assets/enhance/update-check.js
git add src/main.rs
git commit -m "fix: resize all raster images over 1440px including alpha pngs"
git stash pop
rm assets/enhance/update-check.js
```

冲突保留双方, 验证 markers 0 + 测试全绿。Commit message 尾部加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

## 自审记录

- Spec 覆盖: 优化流程 (Task 1)、格式白名单+alpha 跳过 (Task 1 测试)、1920/q85 常量 (Task 1)、更小才替换 (Task 1 c 的 len 比较 + 测试)、失败回退 (Task 1 测试 broken/alpha)、GPU 关闭 (Task 2)。
- 占位符扫描: 无。
- 类型/命名一致性: `EMBED_IMAGE_MAX_EDGE`/`EMBED_IMAGE_JPEG_QUALITY` 与 spec 一致; `optimize_image_for_embed(&[u8], &str) -> Option<Vec<u8>>` 定义与测试调用一致。
