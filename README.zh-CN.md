# PinchDrop

[English](README.md)

在手机照片边缘捏一下，让颜色汇进掌心。张开手，照片里的地方就在眼前展开。仓库自带视频中的四景、配对照片和高斯模型。第一次可以直接玩塞里雅兰瀑布。

## 用 Mac 和 Vision Pro 试玩

1. 在 Mac 上[下载工程 ZIP](https://github.com/xibihe/PinchDrop/archive/refs/heads/main.zip)，解压后用带 visionOS 26 SDK 的 Xcode 打开 `Vision/PinchDrop.xcodeproj`。如果只有 Apple 芯片 Mac，选 **PinchDropPreview → My Mac**，按 **⌘R** 可以先看场景展开。
2. 想从手机上捏取照片，在 Vision Pro 开启开发者模式，与 Xcode 配对，头显系统需要 visionOS 26 或以上。在 Xcode 的 **PinchDrop → Signing & Capabilities** 选择自己的开发团队和可用的 Bundle ID。选 **PinchDrop** scheme、目标选自己的头显，按 **⌘R** 安装。
3. 头显选「塞里雅兰瀑布」，手机打开下表里的瀑布原图，完整显示四边。也可以在头显点分享，把选好的配对照片发到 iPhone。手机只要能显示图片就行。
4. 允许世界感知和手部追踪，选「从手机捏取」。四个角点对齐后，右手先张开，在照片边缘捏住，向外拉。等光粒收进掌心再张手。换景时退出沉浸空间，在头显和手机上选同一景。

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

准备**一张最终构图的 JPEG 或 PNG 原图**，以及**与它相同视角和构图的高斯模型**。制作工具由你选择，请确认工具、权重和素材适用于你的用途。

- **Mac**　我用免费的第三方工具 PhotoSplat 3D，个人推荐，无赞助。在「空间照片」里用原图生成高斯，也可以导入现成的高斯 PLY。「压缩并导出模型」里把目标点数设为自定义 **500000**，不足 50 万点就保持原点数，导出 **SOG v2**。[PhotoSplat 3D](https://www.photosplat3d.com/en/)
- **Windows**　可以自行选工具。非商业科学研究可参考 Apple ML-SHARP 官方的 Python 命令行和模型条款。Vision 可以直接用兼容的高斯 PLY。如果想压成 SOG，安装 PlayCanvas 的转换工具后运行 `splat-transform World.ply World.sog`。[Apple 官方仓库](https://github.com/apple-aiml-research/ml-sharp) · [模型条款](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL) · [PlayCanvas 转换工具](https://github.com/playcanvas/splat-transform)

在仓库根目录执行，换成自己的文件名。Windows 可把 `python3` 换成 `py -3`。

```sh
python3 Tools/add_scene.py "我的照片.jpg" "World.sog" --id my-trip --title "我的旅行" --title-en "My Trip"
```

导入脚本把模型和参考图加入 Vision 应用，登记场景，并将**同一张原图原样复制**到 `Phone/scene-my-trip/Photo.jpg`。把这张图发给手机，重新构建应用即可。需要手机相册网站时可托管整个 `Phone/` 文件夹，分享 `index.html#my-trip`。Vision 支持 SOG v2、标准 SPLAT、兼容的高斯 PLY 和 SPZ，源相机坐标为 X 向右、Y 向下、Z 向前。

**交给编程助手时可以直接说**「请读 AGENTS.md，把这张照片和配对的高斯模型接进 Vision Pro 版，告诉我手机开哪张图、头显选哪一景、怎样运行。」[Agent 接入说明](AGENTS.md)

## 使用条款

自写代码和文档按 PolyForm Noncommercial 1.0.0 公开。仓库内的四组摄影作品及配对素材随 PinchDrop 提供，可用于非商业体验和演示。商业使用或单独复用作品请联系希彼赫。第三方组件保留各自许可。Apple ML-SHARP 的预训练权重限非商业科学研究，条款排除产品开发。仓库分发渲染器、交互和预制场景，没有打包 Apple 的生成代码或权重。[LICENSE](LICENSE) · [NOTICE](NOTICE) · [Apple 模型许可](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL)
