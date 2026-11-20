# PinchDrop

[English](README.md)

看向手机照片，右手隔空捏一下，让颜色汇进掌心。张开手，照片里的地方就在眼前展开。仓库自带视频中的四景、配对照片和高斯模型。第一次可以直接玩塞里雅兰瀑布。想把自己的照片放进去，再看[换成自己的作品](#换成自己的作品)。

## 用 Mac 和 Vision Pro 试玩

1. 在 Mac 上[下载工程 ZIP](https://github.com/xibihe/PinchDrop/archive/refs/heads/main.zip)，解压后用带 visionOS 26 SDK 的 Xcode 打开 `Vision/PinchDrop.xcodeproj`。如果只有 Apple 芯片 Mac，选 **PinchDropPreview → My Mac**，按 **⌘R** 可以先看场景展开。
2. 想从手机上捏取照片，在 Vision Pro 开启开发者模式，与 Xcode 配对，头显系统需要 visionOS 26 或以上。在 Xcode 的 **PinchDrop → Signing & Capabilities** 选择自己的开发团队和可用的 Bundle ID。选 **PinchDrop** scheme、目标选自己的头显，按 **⌘R** 安装。
3. 头显选「塞里雅兰瀑布」，手机打开下表里的瀑布原图，完整显示四边。也可以在头显点分享，把选好的配对照片发到 iPhone。手机只要能显示图片就行。
4. 允许世界感知和手部追踪，选「从手机捏取」。四个角点对齐后，右手先张开，在头显能追踪到右手的任意位置捏住。等光粒收进掌心再张手。预览时可用「释放远近」拉近或推远场景。换景时退出沉浸空间，在头显和手机上选同一景。

| 头显里的场景 | 手机上打开 |
| --- | --- |
| 北京 · 银杏 | [银杏原图](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/00-autumn.jpg) |
| 塞里雅兰瀑布 | [冰岛瀑布原图](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/02-waterfall.jpg) |
| 伊尔库茨克 · 粉色雪夜 | [雪夜原图](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/10-snow.jpg) |
| 伊尔库茨克 · 湖畔 | [湖畔雪景原图](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/11-lake.jpg) |

角点偏移时，量一下手机上**照片本身**从左边到右边的宽度，在头显里填写，并检查画面有没有被裁切。也可以手动定位，或者选「预览释放」直接看展开。应用、Mac 预览和手机相册均支持中英文。

## 要训练 AI 认识照片吗？

不用。每景在 `Vision/App/SceneAssets/Scenes.json` 里都有一个 ID，关联一张参考图和一个提前做好的高斯模型。手机显示原图。Vision Pro 把选中的参考图和实际显示尺寸交给 ARKit，追踪照片位置和手势，从照片取色，再在头显本地展开对应的模型。捏的时候没有网络传图，也无需现场做三维重建。[参考图注册与追踪](Vision/App/StageRenderer.swift) · [捏取与展开](Vision/App/Choreography.swift)

## 换成自己的作品

每一景只需要原图和对应的高斯模型。Apple 将 ML-SHARP 的预训练权重限定于非商业科学研究，许可条款明确排除产品开发，因此 PinchDrop 把模型生成留在应用外。制作工具由你选择，请确认适用于你的用途。已有配对照片和模型，可以直接看下面的**导入并试玩**。[Apple 模型许可](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL)

### 在 Mac 上制作高斯场景

1. 在 Apple 芯片 Mac 上从 App Store 下载 **PhotoSplat 3D**。我用它是因为免费、可以在本机处理照片，个人推荐，无赞助。[Mac App Store 下载](https://apps.apple.com/us/app/photosplat-3d/id6757570552)
2. 选好要在手机上展示的 JPEG 或 PNG，先定好最终裁切。把这张图导入 PhotoSplat 3D，选**「空间照片」**。生成后看一下前景是否对得上原图。手里已有高斯 PLY 和对应照片，也可以从 PLY 开始。
3. 打开**「压缩并导出模型」→「目标点数」→「自定义」**，填 **500000**。原模型不足 50 万点就选「保持原点数」。「导出格式」选 **SOG**，点「开始导出」，把导出的 SOG v2 保存为 `World.sog`，同时保留原图。

**Windows** 可以自行选择制作工具。非商业科学研究可参考 Apple ML-SHARP 官方的 Python 命令行。PinchDrop 可以直接读取兼容的高斯 PLY。要压成 SOG，可安装 PlayCanvas 转换工具，运行 `splat-transform World.ply World.sog`。最后构建并安装到 Vision Pro 需要 Mac 上的 Xcode。[Apple 官方仓库](https://github.com/apple-aiml-research/ml-sharp) · [PlayCanvas 转换工具](https://github.com/playcanvas/splat-transform)

### 导入并试玩

1. 解压 PinchDrop 工程，在包含 `Tools/` 和 `Vision/` 的目录里打开终端。运行下面的命令，把引号里的两个路径换成自己的原图和模型。Windows 可把 `python3` 换成 `py -3`。每个场景使用一个新的 ID。

   ```sh
   python3 Tools/add_scene.py "我的照片.jpg" "World.sog" --id my-trip --title "我的旅行" --title-en "My Trip"
   ```

2. 把脚本打印的 **Phone photo** 发给手机，打开并完整显示四边。上面的 JPEG 示例会生成 `Phone/scene-my-trip/Photo.jpg`。脚本把原图原样复制到这里，也把相同图片和模型登记进了头显应用。
3. 回到 Xcode，选 **PinchDrop** 和自己的头显，按 **⌘R** 重新运行。头显选**「我的旅行」→「从手机捏取」**。等四角对齐，在头显能追踪到右手的任意位置捏住，等光粒汇入掌心再张手。

需要手机相册网站时，可以托管整个 `Phone/` 目录，分享 `index.html#my-trip` 直达这张照片。PinchDrop 支持 SOG v2、标准 SPLAT、兼容的高斯 PLY 和 SPZ。源相机坐标为 X 向右、Y 向下、Z 向前。

**交给编程助手时可以直接说**「请读 AGENTS.md，把这张照片和配对的高斯模型接进 Vision Pro 版，告诉我手机开哪张图、头显选哪一景、怎样运行。」[Agent 接入说明](AGENTS.md)

同一张照片可以配两版模型，分别用不同的场景 ID 导入即可。若某一版要保留 80 万个场景高斯，在那次导入命令末尾加 `--point-budget 800000`。每一景分别记住释放远近和高度。

## 使用条款

自写代码和文档按 PolyForm Noncommercial 1.0.0 公开。仓库内的四组摄影作品及配对素材随 PinchDrop 提供，可用于非商业体验和演示。商业使用或单独复用作品请联系希彼赫。第三方组件保留各自许可。Apple ML-SHARP 的预训练权重限非商业科学研究，条款排除产品开发。仓库分发渲染器、交互和预制场景，没有打包 Apple 的生成代码或权重。[LICENSE](LICENSE) · [NOTICE](NOTICE) · [Apple 模型许可](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL)
