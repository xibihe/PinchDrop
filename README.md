# PinchDrop

[中文说明](README.zh-CN.md)

Pinch a photo off your phone and open your hand to stand inside it. All four scenes from the videos come with the project, including the phone photos and the prepared Gaussian scenes. To try the waterfall, start below. You only need PhotoSplat 3D if you choose it to [make a scene from your own photo](#bring-your-own-photo).

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

PinchDrop uses one original photo and one prepared Gaussian scene. We keep generation outside the app because Apple licenses the ML-SHARP pretrained weights for noncommercial scientific research and excludes product development. You can use any authoring tool licensed for your intended use. If you already have a matching image and model, skip to **Import the pair**. [Apple’s model license](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL)

### Make the scene on a Mac

1. Install **PhotoSplat 3D** on your Apple silicon Mac. I use it because it’s free and processes photos locally. This is an unsponsored recommendation. [Mac App Store](https://apps.apple.com/us/app/photosplat-3d/id6757570552)
2. Pick the JPEG or PNG you want to display on your phone. Finish cropping it first, then import that file into PhotoSplat 3D and choose **Spatial Photo**. Once the scene appears, check that the foreground lines up with the photo. You can also start with an existing Gaussian PLY and its matching photo.
3. Open **Optimize & export a model → Target Points → Custom** and enter **500000**. If the model already has fewer points, choose **Keep all points**. Under **Export Format** select **SOG**, then **Start Export**. Save the SOG v2 file as `World.sog` and keep the original photo.

**On Windows**, choose your own authoring tool. For noncommercial scientific research, Apple documents its ML-SHARP Python CLI and Gaussian PLY output. PinchDrop accepts compatible Gaussian PLY directly. For a smaller SOG, install the PlayCanvas CLI and run `splat-transform World.ply World.sog`. To build and install the Vision Pro app, use Xcode on a Mac. [Apple ML-SHARP](https://github.com/apple-aiml-research/ml-sharp) · [PlayCanvas converter](https://github.com/playcanvas/splat-transform)

### Import the pair

1. Open Terminal in the unzipped PinchDrop folder containing `Tools/` and `Vision/`. Run the command below, replacing the two quoted file paths with your own. On Windows, use `py -3` in place of `python3`. Choose a new ID for each scene.

   ```sh
   python3 Tools/add_scene.py "MyPhoto.jpg" "World.sog" --id my-trip --title "My Trip"
   ```

2. Send the **Phone photo** printed by the script to your phone and open it full-frame. For this JPEG example, it’s `Phone/scene-my-trip/Photo.jpg`. The script copies the original image byte for byte and registers it alongside the model.
3. In Xcode, run **PinchDrop** on the headset again with **⌘R**. Select **My Trip → Pick up from phone**. Wait for the four markers, pinch the edge of the photo, then open your hand.

If you host the whole `Phone/` folder, `index.html#my-trip` opens that scene’s photo directly. PinchDrop accepts SOG v2, standard SPLAT, compatible Gaussian PLY and SPZ. Source camera axes are right, down and forward.

**Using a coding assistant?** Give it the two files and say “Read AGENTS.md, add my photo and matching Gaussian scene for Vision Pro, and tell me which image to open on my phone and how to run it.” [Agent guide](AGENTS.md)

## Terms

Original code and documentation are source-available under PolyForm Noncommercial 1.0.0. The four photographic works and their paired assets are included for noncommercial use with PinchDrop. For commercial use or reuse of the artworks separately, contact 希彼赫 (XBH). Third-party components retain their own terms. Apple's pretrained ML-SHARP weights are separately licensed for noncommercial scientific research, which excludes product development. PinchDrop includes the renderer, interaction and prepared scenes. The project does not distribute Apple's generator or weights. [License](LICENSE) · [Notices](NOTICE) · [Apple model terms](https://github.com/apple-aiml-research/ml-sharp/blob/main/LICENSE_MODEL)
