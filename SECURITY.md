# Security & Privacy

Clipboard data is some of the most sensitive data on a computer. Clipivo's rules:

1. **Local only.** No account, no server, no telemetry, no third-party analytics. Clipboard data never leaves the Mac. Two features use the network: **update checks** (off by default; daily when turned on in Settings ▸ General, or on demand with Check Now / "Check for Updates…") request `api.github.com/repos/jishnumahanta/clipivo/releases` at most once a day, without cookies, credentials or identifiers, never download or install anything, and only open pages under the official releases URL; and **"Fetch page titles for copied links"** (off by default) requests the copied URL itself.
2. **No content in logs.** Clipivo never logs clipboard contents; error messages describe storage state only.
3. **Owner-only files.** The library directory is `0700`; the database, its WAL/SHM files, blobs and private payloads are `0600`.
4. **Exclusions happen before reading.** When the frontmost (or `org.nspasteboard.source`-declared) app is ignored, or monitoring is paused, the pasteboard contents are not read at all — no storage, thumbnails, OCR or network.
5. **Respecting other apps' markers.** `org.nspasteboard.TransientType` content is never stored. `ConcealedType` content and copies from known password managers are discarded by default.
6. **Heuristic sensitive-content detection.** Private keys, JWTs, well-known API key formats (AWS, GitHub, Stripe, Slack, OpenAI/Anthropic-style, Google, GitLab, npm, SendGrid, Hugging Face), bearer tokens, `SECRET=`-style environment assignments, credentials in URLs, Luhn-valid card numbers and one-time codes. Policies: Always save / Save as private / Ask / Never save. **Detection is a safety net, not a guarantee.**
7. **Private clips.** Encrypted with AES-256-GCM; the key is a random 32-byte value in the login Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Private clips are excluded from the content search index, thumbnails and OCR, hidden in the UI, and require Touch ID / password to view, paste or export.
8. **App lock.** Optional Touch ID / password lock hides history and search results; it relocks after an idle timeout and on sleep/screen lock. Capture continues while locked (pause monitoring separately if needed).
9. **Accessibility is used for one thing:** posting ⌘V to the app you were using. Clipivo does not read other apps' UI.
10. **Untrusted input.** Clipboard data is treated as hostile: representation sizes are capped (configurable), regexes are linear-time and bounded (with regression tests for pathological input), image decoding is header-only or downsampled, and malformed data is skipped rather than crashing.
11. **Archives.** Exports exclude private clips unless you authenticate and explicitly choose to include them (they are then written decrypted — store the file safely). Imports verify each payload's SHA-256.

## Known limitations

- Without a stable code-signing identity, macOS may ask again for Keychain and Accessibility access after updates.
- The database itself is not encrypted (only private clips are). FileVault protects data at rest; the storage layer is structured so an encrypted database (e.g. SQLCipher) can be introduced behind the same API.
- Other processes running as your user can read your user's files; that is macOS's model for non-sandboxed apps.

## Reporting a vulnerability

Please report security issues privately, **not** in a public GitHub issue.

- **Email:** jishnumahanta17@gmail.com, with the subject "Clipivo security"
- Include the Clipivo version (Settings ▸ General ▸ About), your macOS version, the steps to
  reproduce, and the impact you expect.
- You'll get an acknowledgement within 7 days. Fixes for confirmed issues are prioritised over
  feature work and credited in the changelog if you'd like.

Good-faith research on your own devices and your own data, within [LICENSE](LICENSE) section 2(c), is
welcome. Please don't access other people's data, and give a reasonable window to ship a fix before
disclosing publicly.

**Supported versions:** only the latest release (including betas) receives security fixes.
