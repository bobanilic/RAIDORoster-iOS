# Crew Documents · 2.21.0

Open **Today → document icon** or **Settings → Documents**. The fixed Midnight theme and existing roster, pay and announcement behavior are retained.

## Features

- One private Documents area: Passport & visas, Crew certificates, Medical, Vaccinations, Travel and Other.
- Import a PDF, JPEG, PNG or HEIC from Files, select a photo, or scan paper documents with the native scanner. Images/scans become PDFs; imported PDFs retain their original bytes.
- Native PDF viewing/zoom, explicit system sharing, search, names, categories, pinning, deletion with confirmation, optional expiry/renewal date.
- Optional generic local reminders at 09:00, 30/7/1 days before the supplied date. Past trigger dates are skipped. Notification permission is requested only when enabling reminders; titles/content do not reveal the document name or category. Pending limits are reported rather than silently promising all alerts.
- 25 MB per file, up to 20 scan pages, 100 files/250 MB total. PDF imports are limited to 500 pages; password-locked PDFs need an unlocked copy.

## Protection and lifecycle

- AES-GCM encrypts the metadata index and each document independently. Authenticated context binds blobs to UUIDs and separates the index from file content.
- The 256-bit key is stored in Keychain with user presence and `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`. Face ID, Touch ID or the device passcode authorizes opening the vault. Missing/unreadable keys and corrupt indexes fail closed without resetting saved data.
- Files use complete iOS file protection. The vault directory is excluded from device/cloud backup; there is no automatic upload, analytics or sync for document content. Keep originals: app deletion, loss of the device, removal of its passcode or a change in signing identity can make these local copies unavailable.
- A foreground authorization session identifies every storage operation. Work started before locking cannot commit into a later unlocked session. Backgrounding drops the in-memory key, index and preview; a separate opaque window covers document sheets as the app becomes inactive, before app-switcher capture.
- Explicit sharing hands a PDF to the native transfer system. Recipient apps and destinations control exported copies. The app does not create persistent plaintext export files. Imported originals remain where the user selected them.
- Atomic file/index writes and rollback avoid advertising an incomplete import. Deletion commits removal from the index before unlinking its encrypted blob; an interrupted unlink can leave an unreferenced encrypted file. No automatic recovery deletes files after a failed authentication.

## Verification

`tests/CrewDocumentChecks.swift` exercises encryption round trips, wrong keys, corruption, ciphertext swapping, locked/stale-session access, failed index commits, deletion, limits, date validation and reminder dates. The existing macOS workflow runs these checks and builds the complete iOS app.

Device acceptance still needs Face ID/passcode cancellation and fallback, Files/Photos/camera permissions, scanner, PDF sharing, background masking and notification delivery. Simulator builds alone cannot establish all of these behaviors on the owner's device.

Implementation uses Apple's [CryptoKit and data-protection guidance](https://developer.apple.com/videos/play/wwdc2019/709/), [LocalAuthentication authorization guidance](https://developer.apple.com/videos/play/wwdc2022/10108/), and [Transferable sharing API](https://developer.apple.com/videos/play/wwdc2022/10062/).
