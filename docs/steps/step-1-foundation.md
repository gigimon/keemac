# Step 1: Foundation and app skeleton

## Scope
- Create a buildable macOS app baseline with SwiftUI entrypoint.
- Set deployment target to macOS 14+.
- Separate architecture into `App`, `Domain`, `Data`, `UI`.
- Define baseline error model for vault loading.
- Add a working KDBX backend integration for MVP baseline.

## Decisions
- Use Swift Package as project baseline to keep setup lightweight and modular.
- Use `MVVM + Observable` in UI layer.
- Keep real KDBX parsing behind `VaultLoading` protocol.
- Use `KeePassKit` backend (option B) and vendor compiled `xcframework` artifacts (`KeePassKit` + `KissXML`) as local binary targets.

## Progress
- [x] Created modular package layout (`Sources/App`, `Sources/Domain`, `Sources/Data`, `Sources/UI`).
- [x] Added SwiftUI app entrypoint and first root screen.
- [x] Set platform target to macOS 14+ in `Package.swift`.
- [x] Added `VaultError` with core error categories.
- [x] Added `VaultLoading` protocol and concrete `KeePassKitVaultLoader`.
- [x] Added local binary targets in SPM (`Vendor/KeePassKit.xcframework`, `Vendor/KissXML.xcframework`).
- [x] Implemented KDBX open/decrypt/parse mapping (`KPKTree(contentsOf:key:)`) into domain models.
- [x] Added reproducible vendor bootstrap script (`scripts/build_vendor_frameworks.sh`).
- [x] Verified baseline build and launch process with `swift build` and `swift run KeeMacApp`.
- [x] Wired concrete parser backend and validated integration build.

## Risks
- `KeePassKit` is GPL-licensed. Product/distribution implications must be validated before release decisions.
- Vendored frameworks are currently arm64-focused build artifacts; universal/distribution-grade artifacts should be produced in release hardening.

## Next
- Move to `Step 2` and complete file loading UX details (retry, richer errors, loading state polish).
- Add a real `.kdbx` fixture and smoke tests for invalid password / parse failure mapping.
