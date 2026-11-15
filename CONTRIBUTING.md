# Contributing to UltaMac

Thanks for helping! Anyone can fork the repo, make changes and open a pull request.

## Ground rules
1. **Offline only.** No networking, analytics, accounts or remote config. PRs that add network calls won't be merged.
2. **Safety first.** Every removal must go through `FileRemover` → `SafetyPolicy` and the review sheet. Never clear file flags, bypass SIP/TCC/Gatekeeper, or delete without confirmation. Disk writes must pass `DiskSafetyGate` and revalidation.
3. **Real data only.** No fake progress, invented scores or decorative buttons that do nothing.
4. **Original work.** Don't copy code, assets or sounds from other products.
5. **Tests.** Add or update tests in `Tests/UltaMacCoreTests` and run `swift test` before opening a PR. Destructive disk tests must only use scratch disk images.

## Getting started
```bash
git clone https://github.com/ray0189/UltaMac.git
cd UltaMac
swift test
scripts/build-app.sh   # builds build/UltaMac.app
```

Layout: `Sources/UltaMacCore` holds the engines (no UI, unit-tested); `Sources/UltaMac` holds the SwiftUI app. Design tokens and components are in `Sources/UltaMac/Design`; see `docs/` for architecture and the security model.
