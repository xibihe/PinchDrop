# PinchDrop

[中文说明](README.zh-CN.md)

Pinch a photo off your phone and open your hand to stand inside it. All four scenes from the videos come with the project, including the phone photos and the prepared Gaussian scenes. You can start with the waterfall.

## Try it on Vision Pro

1. On your Mac, [download the project ZIP](https://github.com/xibihe/PinchDrop/archive/refs/heads/main.zip) and unzip it. Open `Vision/PinchDrop.xcodeproj` in Xcode with the visionOS 26 SDK. For a quick look on an Apple silicon Mac, choose **PinchDropPreview → My Mac → Run**. This previews the reveal.
2. For the hand interaction, use a paired Vision Pro running visionOS 26 or later with Developer Mode enabled. In Xcode select the **PinchDrop** target, open **Signing & Capabilities**, select your development team and use a bundle identifier available to you. Choose the **PinchDrop** scheme and your headset as the destination, then press **⌘R**.
3. Select **Seljalandsfoss** in the headset. Open the [waterfall photo](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/02-waterfall.jpg) on your phone and fit the entire image on screen. You can also use the share button in the headset to send the selected photo to an iPhone. Any phone that can display the image works.
4. Allow world sensing and hand tracking. Choose **Pick up from phone**. When the four corner markers align, open your right hand, pinch the edge of the photo and pull away. When the particles have gathered in your palm, open your hand. To switch scenes, exit the immersive space and select the next scene on both devices.

| Scene in the headset | Open on the phone |
| --- | --- |
| Beijing · Ginkgo | [Autumn ginkgo](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/00-autumn.jpg) |
| Seljalandsfoss | [Icelandic waterfall](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/02-waterfall.jpg) |
| Irkutsk · Pink Snow at Night | [Snowy street at night](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/10-snow.jpg) |
| Irkutsk · Snow by the Lake | [Snow by the lake](https://raw.githubusercontent.com/xibihe/PinchDrop/main/Phone/11-lake.jpg) |

**If the markers miss the edges**, measure the width of the actual image on the phone, enter it in the headset controls and check that all four edges are visible. Manual placement is also available. To view the release without a phone, choose **Preview reveal**. The app, desktop preview and phone gallery include English and Chinese.

## How does it recognize my photo?

Each scene ID in `Vision/App/SceneAssets/Scenes.json` pairs one reference image with one prepared Gaussian model. The phone displays the original image. When you select a scene, Vision Pro registers that image and its displayed physical size with ARKit. The headset tracks the image and your hand, samples the photo colors and renders the paired scene locally. Adding a photo requires no AI training, cloud recognition or file transfer during the pinch. [Tracking code](Vision/App/StageRenderer.swift) · [Gesture and reveal](Vision/App/Choreography.swift)

## Bring your own photo

Prepare the final JPEG or PNG and a Gaussian scene made from the same viewpoint and crop. Use a workflow licensed for your intended use.

- **Mac.** I use PhotoSplat 3D. It’s a free third-party tool and this recommendation is unsponsored. Generate a scene from the final image in the spatial-photo workflow, or import an existing Gaussian PLY. In the compression/export panel, set a custom target of **500,000** points (keep the original count if smaller) and export **SOG v2**. [PhotoSplat 3D](https://www.photosplat3d.com/en/)
- **Windows.** Choose your own authoring tool. For noncommercial scientific research, Apple documents its ML-SHARP Python CLI and its Gaussian PLY output. Vision accepts compatible Gaussian PLY directly. If you want a smaller SOG, PlayCanvas documents the conversion command `splat-transform World.ply World.sog` after installing its CLI. [Apple ML-SHARP](https://github.com/apple-aiml-research/ml-sharp) · [Apple model license](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL) · [PlayCanvas converter](https://github.com/playcanvas/splat-transform)

From the repository root, run the following with your own files (use `py -3` on Windows).

```sh
python3 Tools/add_scene.py "MyPhoto.jpg" "World.sog" --id my-trip --title "我的旅行" --title-en "My Trip"
```

The importer registers the pair in the Vision app and copies the exact photo to `Phone/scene-my-trip/Photo.jpg`. Send that image to the phone and rebuild the app. You can host the entire `Phone/` folder together and share `index.html#my-trip`. Vision accepts SOG v2, standard SPLAT, compatible Gaussian PLY and SPZ. Source camera axes are right, down and forward.

**Using a coding assistant?** Give it the two files and say “Read AGENTS.md, add my photo and matching Gaussian scene for Vision Pro, and tell me which image to open on my phone and how to run it.” [Agent guide](AGENTS.md)

## Terms

Original code and documentation are source-available under PolyForm Noncommercial 1.0.0. The four photographic works and their paired assets are included for noncommercial use with PinchDrop. For commercial use or reuse of the artworks separately, contact 希彼赫 (XBH). Third-party components retain their own terms. Apple's pretrained ML-SHARP weights are separately licensed for noncommercial scientific research, which excludes product development. PinchDrop includes the renderer, interaction and prepared scenes. The project does not distribute Apple's generator or weights. [License](LICENSE) · [Notices](NOTICE) · [Apple model terms](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL)
