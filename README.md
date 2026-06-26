# BvfAppKit

Swift library built on [BvfKit](https://github.com/openbvf/BvfKit) for apps to capture and consume encrypted media without temp files ever touching disk.

* No lock-in. Everything's a file named by date, decryptable with [bvf-cli](https://github.com/openbvf/bvf/tree/main/bvf-cli).
* No network calls. The library never opens a socket.
* iCloud is optional, used only as a transport for already-encrypted files. Opt in to sync captures from any device to the one holding the private key.
* Passphrase-driven unlock.
* Lazy on-demand decryption to screen.
* Idle timeout.
* Encrypted metadata.
* SwiftUI view-model machinery that wires it all together.

Used by Bedit (journal), Bimage (gallery), BvfAudio (audio + transcription), and BvfVideo (video). If you're evaluating any of those, the substantive logic lives here; the apps themselves are thin shells.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/openbvf/BvfAppKit.git", from: "<version>")
]
```

## Two modules

### `BvfAppKit`
Shared iOS + macOS surface. No private key in scope.
- Capture-side encryption: `CryptoService`, `PushEncryptionContext`, `KeyFile`
- Storage layout and staging: `iCloudManager`, `StagingManager`
- Configuration and small shared UI

### `BvfAppKitDecrypt`
macOS-only. Requires access to the private key.
- `DecryptionSession` lazy on-demand decryption after unlock
- `BrowseViewModelBase` shared unlock + date-range + tag filtering
- Key generation, decrypt-side `CryptoService` extensions
- File watching, sync, search, concurrency limiter
- `IdleTimer` tears the session down on inactivity

iOS apps `import BvfAppKit`. macOS apps add `import BvfAppKitDecrypt`.

The asymmetry is structural, not a build flag. iOS cannot decrypt because the private key never lives there. That asymmetry is the whole reason for the split.

## Relationship to BvfKit

BvfKit handles raw cryptography: `Encrypter`, `Decrypter`, `Keypair`, secretstream chunking, key derivation, zeroization. BvfAppKit handles the app concerns BvfKit stays out of: where files go, how lazy decryption is rate-limited, how the unlock flow is modeled, how SwiftUI view models compose all of it.
