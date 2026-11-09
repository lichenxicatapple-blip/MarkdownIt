# MarkdownIt! 品牌资源

图形和配色集中维护在本目录：

| 维护源 | 内容 |
| --- | --- |
| `mark.svg` | 唯一矢量母版；连写 `md` 与感叹号路径、墨蓝色光影、瓷白背景及首页圆角路径 |
| `brand.json` | 图标包名称、背景分组和首页裁剪路径的标识 |

标志采用自由连写的 `md` 与独立的手写感叹号，以墨蓝色渐变和细边高光呈现笔势。瓷白背景带有轻微冷灰过渡，保持字形与背景的明度层次。字形为路径，不依赖字体或位图；形状、颜色和光影都在母版内维护。浅色与深色界面使用同一品牌配色。

## 生成与检查

修改母版或配色后，在仓库根目录运行现有资源命令：

```sh
python3 scripts/build_native_web.py
python3 scripts/build_native_web.py --check
```

该命令调用 `scripts/build_brand_assets.swift`，用 macOS AppKit 生成 1024 × 1024、sRGB PNG，并统一生成以下资源。生成文件随源码提交；不要手动修改。

| 生成位置（仓库根目录下） | 内容 |
| --- | --- |
| `design/brand/production/` | 透明标志、完整 App 图标、Icon Composer 图标包及导出清单 |
| `MarkdownIt/Assets.xcassets/BrandMark.imageset` | 包含背景的首页矢量与资源描述；保留原始颜色 |

`--check` 重新生成并比较所有资源，遗漏更新、直接修改或遗留文件都会使检查失败。CI 和模拟器验证复用同一入口。

Icon Composer 图标包按母版顶层分组自动生成图层，沿用 SVG 的绘制顺序，不在生成器中维护图形名称或配色。背景也是矢量图层，保留母版的渐变；已有光影不重复叠加系统玻璃效果。在 Icon Composer 中核对 `production/MarkdownIt.icon` 的浅色、深色与着色外观；调整回到母版。系统图标使用完整方形背景，由系统处理外形；首页导出使用母版中的圆角路径裁剪。
