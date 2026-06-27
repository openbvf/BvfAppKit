# Security

BvfAppKit's overriding design principle: plaintext never touches disk during capture or consumption. This file covers the app-lifecycle surface that apps built on it share.

## Reporting vulnerabilities

If you find a security issue, **do not open a public issue.** Instead:

- **GitHub Security Advisories** (preferred): [Submit a private advisory](https://github.com/openbvf/BvfAppKit/security/advisories/new)
- **Email**: bvf@newvoll.net

## Out of scope

- Encryption, key derivation, libsodium interop: [BvfKit/SECURITY.md](https://github.com/openbvf/BvfKit/blob/main/SECURITY.md).
- The `.bvf` file format and its threat model: [bvf/SECURITY.md](https://github.com/openbvf/bvf/blob/main/SECURITY.md).
- App-specific surface: the consuming app's own SECURITY.md.

## In scope

### Plaintext never written to disk

BvfAppKit's capture path encrypts in-stream; only ciphertext reaches a file on disk. Decryption produces plaintext only in memory. Heap memory holding plaintext can still be swapped to disk by the OS; only the private key sits in non-swappable memory.

### Decrypted content in memory

If an adversary has access to running memory, all bets are off. SwiftUI's internal storage can copy plaintext at any time and is not accessible to BvfAppKit; memory hygiene is best-effort. Apps dismiss views on lock to bound how long copies live.

### `DecryptionSession` contract

While a session is alive, the private key sits in non-swappable memory that's zeroed on free. When the consuming app calls `clearSensitiveData(reason:)`, the session is destroyed and the key bytes are wiped.

**Apps building on BvfAppKit MUST invoke `clearSensitiveData` on lock, idle, and quit.** Failure to do so leaves the private key resident. `IdleTimer` handles the idle case; `BrowseModalsModifier` handles the standard system events (sleep, lock, terminate, shutdown). Apps wiring both rarely need to call `clearSensitiveData` explicitly.

### `IdleTimer`

Triggers `clearSensitiveData` on inactivity. Session teardown is BvfAppKit's part; tearing down view state to evict framework-held plaintext is on the app.

### iCloud mode semantics

- **Standard Mode**: requires a private key file and a folder URL.
- **iCloud Write-Only Mode**: requires iCloud Drive to be available. The private key is not on this device, and there is no local fallback. If iCloud becomes unavailable, the app is unusable until iCloud is restored.

### Core dumps

BvfAppKit provides `DisableCoreDumps.apply()`. Apps must call it from their `init` to prevent the OS from spilling process memory to disk on crash; process memory contains the unlocked private key while a session is open.
