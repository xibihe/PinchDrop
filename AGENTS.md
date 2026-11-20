# PinchDrop development notes · 开发交接

## 带第一次使用的人接入作品 · First-time setup

For a first demo, follow [Try it on Vision Pro](README.md#try-it-on-vision-pro). Start with Seljalandsfoss on the headset and open the waterfall phone link from the same table. Mac preview uses the PinchDropPreview scheme. Running the hand interaction on Vision Pro uses Xcode with the visionOS SDK, a development team, a paired headset and the PinchDrop scheme. Phone image tracking registers the selected reference with ARKit at runtime. Nobody needs to train an image classifier.

1. 先确认对方要体验示例还是换自己的作品。体验示例时，给对方 `Phone/02-waterfall.jpg`，在头显选「塞里雅兰瀑布」。换作品时请对方提供最终显示的 JPEG/PNG 和从同一视角制作、可用于预期用途的高斯。沿用原图的裁切、方向与颜色。 / For the sample, give the viewer `Phone/02-waterfall.jpg`. For a custom scene, ask for the final photo, the matching Gaussian file.
2. 从仓库根目录执行 README 中的 `Tools/add_scene.py` 命令。给每景一个唯一 ID、中英文标题。只有原图时，引导对方按[中文制作教程](README.zh-CN.md#换成自己的作品)准备模型。Windows 的工具由创作者自行选择。 / If the creator has only a photo, start with [Bring your own photo](README.md#bring-your-own-photo). Once the model is ready, run the importer with a unique ID and titles.
3. 把脚本打印的手机图片路径交给对方。已有静态相册地址时给出带场景 ID 的直达链接。重新构建目标应用，核对手机原图与应用参考图逐字节一致，用同名场景试一次捏取和展开。现场头显测试单独记录。 / Hand back the phone photo or hosted deep link, rebuild, and verify the same scene and photo. Record headset testing separately.

- The stable scene ID maps one reference image to one prepared Gaussian cloud. On Vision the selected scene registers its own ARKit reference image. Keep the phone image pixel-identical to the paired reference.
- Vision/App/StageRenderer.swift reads tracked images and hand joints. PhotoTracking.swift confirms the pose. Choreography.swift samples photo color, starts particles at physical coordinates on that photo, transfers them to the hand, and starts the reveal in the palm. Vision/App/Glow.metal and the vendored MetalSplatter renderer implement the visual output.
- Phone shares or downloads happen before the performance. No file or model is transmitted by the pinch gesture. Runtime model generation is outside this repository.
- Run the pickup regression from Vision: `xcrun swiftc -O App/Choreography.swift App/PhotoTracking.swift App/PhotoColors.swift Tests/PhotoPickupChecks.swift -o /tmp/PhotoPickupChecks && /tmp/PhotoPickupChecks App/SceneAssets/Phone.jpg`. Check phone portrait, landscape, language persistence and direct links. Confirm optical alignment, stationary phone calibration, stereo rendering and hand behavior on the actual device. Resetting an experience should require a new open-to-pinch gesture.
- 发行包随附视频里的四组摄影作品及对应模型和道具。第三方模型权重单独获取。新增场景分别核对图片、模型和道具的发布权。自写代码的限制以根目录 LICENSE 为准，第三方材料详见 NOTICE。


### 场景首次进入回归

每次打开沉浸空间都用独立 UUID 将窗口与对应的 StageControl 配对。渲染器只能领取该次请求，避免上一次空间的回调更新新窗口。每次动作等带有效头部位姿的内置屏帧提交并由 GPU 完成后才报告已加载。预览先启动头部追踪，捏取再请求互动权限。使用 Xcode 的 PinchDrop scheme 在 visionOS 模拟器运行 ⌘U，SceneEntryUITests 会检查冷启动、退出后快速重进、预览及捏取入口，并在有多景时切换照片核对场景名称。
