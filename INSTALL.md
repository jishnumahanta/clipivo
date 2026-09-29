# Installing the Clipivo beta

Clipivo is in free public beta. The beta isn't notarized by Apple yet, so macOS asks you to confirm the first launch. This is a one-time step.

## 1. Install

1. Download `Clipivo-<version>.dmg` from the [Releases page](https://github.com/jishnumahanta/clipivo/releases) and double-click it. (Prefer a zip? Download `Clipivo-<version>.zip` and double-click it to unzip.)
2. Drag **Clipivo** onto the **Applications** folder, then eject the disk image.
3. Open it:
   - **macOS 15 Sequoia and later:** double-click Clipivo. When macOS says it can't verify the app, click **Done**. Then open **System Settings ▸ Privacy & Security**, scroll down, click **Open Anyway** next to the Clipivo message and confirm.
   - **macOS 14 Sonoma:** right-click (or Control-click) Clipivo ▸ **Open** ▸ **Open**.

Optional — check the download matches the published checksum:

```bash
shasum -a 256 ~/Downloads/Clipivo-*.dmg
```

## 2. Allow automatic paste

Clipivo pastes the clip you choose into the app you were typing in. macOS requires **Accessibility** access for that:

**System Settings ▸ Privacy & Security ▸ Accessibility ▸ turn on Clipivo.**

Without it, Clipivo still works: clicking a clip copies it, and you press ⌘V yourself.

If Clipivo is already switched on but pasting doesn't work, select it, remove it with **−**, add it again with **+**, then quit and reopen Clipivo.

## 3. Use it

- Copy things as usual — Clipivo keeps them, forever by default, only on your Mac.
- Press **⇧⌘V** anywhere to open your clipboard. Type to search, click a card (or press Return) to paste.
- Menu bar icon ▸ Settings to change the shortcut, layout, privacy options and more.

## Updating

Download the new version and replace Clipivo.app in Applications (quit Clipivo first). Your history is stored separately in `~/Library/Application Support/Clipivo` and is kept.

## Uninstalling

Quit Clipivo, delete Clipivo.app, and (to remove your history) delete `~/Library/Application Support/Clipivo`. Optionally remove the “Clipivo private clip key” item in Keychain Access.

## Privacy

Clipivo has no account, no cloud and no analytics. Everything stays on your Mac. See [SECURITY.md](SECURITY.md).

---

## For maintainers: signing beta releases for free

Use one self-signed certificate for every beta release, so testers keep their permissions across updates:

1. Keychain Access ▸ Certificate Assistant ▸ **Create a Certificate…**
2. Name: `Clipivo Beta` · Identity Type: **Self-Signed Root** · Certificate Type: **Code Signing** ▸ Create.
3. Set **Validity Period** to 3650 days (tick *Let me override defaults*), then in Keychain Access set the certificate's **Trust › Code Signing** to **Always Trust**. `security find-identity -v -p codesigning` should list it.
4. Bump the `VERSION` file, then run `scripts/make-release.sh`. The scripts sign with "Clipivo Beta" automatically when it's installed.
5. Upload `dist/release/Clipivo-<version>.dmg`, `Clipivo-<version>.zip` and their `.sha256` files to a GitHub Release.

Back up that certificate (export it from Keychain Access as .p12). If it's lost, testers must re-grant Accessibility once after the next update.
