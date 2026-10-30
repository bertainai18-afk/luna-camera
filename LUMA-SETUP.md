# Luma Camera

Luma is an independent camera app inspired by the idea of shooting first and refining later. It does not reproduce Chromagraph's proprietary image processing. Photos and adjustments are stored on the device; deleting the app deletes its private gallery. Export important photos to Photos for safekeeping.

## Build and install from Windows

1. Create a GitHub repository and upload the **contents** of this folder, including the hidden `.github` folder. A public repository can use GitHub's free standard macOS runners; a private one is subject to its included allowance and billing limits.
2. Open the repository's **Actions** tab, enable workflows if prompted, and run **Build iPhone app**. Open the completed run and download `Luma-unsigned-ipa` under Artifacts. Unzip it to get `Luma-unsigned.ipa`.
3. Install AltStore Classic on your iPhone using [its Windows instructions](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). Install the IPA from AltStore's My Apps tab. You may need to enable Developer Mode under Settings > Privacy & Security after installation.
4. Keep AltServer available to refresh the app. Free-account installations expire after seven days unless refreshed. Enter Apple credentials only in the installer you trust, never in GitHub or a chat.

Builds and hardware behavior have not been tested on an iPhone. If the build fails, open the failed Actions step and share its error log. GitHub account permissions, runner availability, and AltStore/iOS compatibility can change.

## Using Luma

Allow camera access, then tap the shutter. Luma requests a RAW capture when the active camera reports support; otherwise it stores a processed photo. Tap the gallery button to view and edit. Adjustments are saved separately from the original. Export creates a JPEG in the Photos library; deleting a gallery item permanently removes its private original. Capture, rendering, and saving occur locally.

RAW availability, resolution, orientation, performance, and the rendered look depend on the device and must be checked on hardware. The rendering is an original Core Image treatment, not an emulation of another app's color science. This first version does not provide 48 MP selection, lens switching, flash, HEIC export, auto-export, or Apple Watch support.

