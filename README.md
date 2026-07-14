# WatchtowerCore (iOS)

Native iOS tap-capture engine for [SitePong Watchtower](https://sitepong.com) —
pure Swift / UIKit / SwiftUI, **no React Native, no Expo, no npm**.

This is the public source distribution of the same bridge-free engine that ships
inside the React-Native `Sitepong` pod, published so native iOS apps can consume
it without access to the private SitePong monorepo.

## Install (CocoaPods)

```ruby
pod 'WatchtowerCore',
  :git => 'https://github.com/sitepong/watchtower-ios.git',
  :tag => 'v0.1.0'
```

## Install (Swift Package Manager)

```
https://github.com/sitepong/watchtower-ios.git  →  up to next major from 0.1.0
```

## Usage

```swift
import WatchtowerCore

Watchtower.start(
    apiKey: "YOUR_KEY",
    projectId: "YOUR_PROJECT_ID",
    endpoint: URL(string: "https://ingest.sitepong.com")!
)

// Optional
Watchtower.setScreen("Checkout")
Watchtower.setUser("user_123", email: "a@b.com", name: "Ada")
Watchtower.stop()
```

Only depends on system frameworks: `UIKit`, `CoreImage`, `Foundation`, `SwiftUI`.

---

> **Maintainers:** this repo is a mirror. The canonical source lives at
> `packages/sdk/ios/WatchtowerCore/*.swift` in the SitePong monorepo. Update
> there and re-sync — do not edit `Sources/` here by hand.
