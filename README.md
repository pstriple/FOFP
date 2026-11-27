This tweak hooks into iOS’s iTunes Store / App Store daemon (`itunesstored`) to silently suppress and auto-complete background Apple ID `"refetch"` authentication requests—preventing login popups and authorization failures when an app or piece of content belongs to an Apple ID that isn't currently signed into the device.

Because Apple restructured how `itunesstored` handled account authorization between iOS 6 and iOS 7+, the tweak splits its behavior across two version paths at runtime using `kCFCoreFoundationVersionNumber <= 793.0` (`793.0` is iOS 6.0/6.1; iOS 7.0 starts at `847.2`):

---

### 1. Initialization & Runtime Hooking (`%ctor`)

When injected into the target process (`itunesstored`), the constructor:

* Checks whether the device is running **iOS 6** (`kCFCoreFoundationVersionNumber <= 793.0`) or **iOS 7–10**.
* Verifies via the Objective-C runtime (`objc_getClass` and `class_getInstanceMethod`) that the private `StoreServices` / `iTunesStore` classes and methods exist before hooking them, preventing crashes if Apple changes internal APIs.
* **On iOS 6:** Hooks only `-[AuthorizeMachineOperation _newAuthenticationContext]`.
* **On iOS 7–10:** Allocates a shared `NSMutableSet` to track account identifiers and additionally hooks `-[AuthenticateOperation initWithAuthenticationContext:]` and `-[AuthenticateOperation run]`.

---

### 2. Intercepting Machine Authorization (`AuthorizeMachineOperation`)

When iOS validates or refreshes FairPlay machine authorization for an app, `AuthorizeMachineOperation` builds an authentication context via `_newAuthenticationContext`:

* The tweak lets the original method create the context, then inspects its `reason` property.
* If `reason` equals `@"refetch"`, the tweak forces the operation's `promptStyle` to `1000` (`0x3e8`), telling the StoreServices framework to treat the request as a silent/background prompt rather than presenting a UI dialog.
* **On iOS 6**, setting `promptStyle = 1000` here is enough to suppress the prompt.
* **On iOS 7–10**, `itunesstored` performs stricter downstream authentication checks, so the tweak also:
1. Reads the operation's `requiredUniqueIdentifier` (the Apple ID DSID tied to the item) and stores its string description in the thread-safe `NSMutableSet`.
2. Attaches an `@YES` marker to the `AuthorizeMachineOperation` instance via `objc_setAssociatedObject`.



---

### 3. Propagating the Bypass Marker (`AuthenticateOperation` Init)

On iOS 7–10, `itunesstored` passes the authentication context into an `AuthenticateOperation`:

* Inside `-[AuthenticateOperation initWithAuthenticationContext:]`, the tweak checks the incoming context using its helper (`HasRefetchMarkerOrTrackedUID`), which returns `YES` if the object either carries the associated `@YES` marker or has `promptStyle == 1000` with a `requiredUniqueIdentifier` present in the tracked set.
* If matched, the tweak copies the `@YES` associated-object marker onto both the new `AuthenticateOperation` instance and its `authenticationContext` so the state persists through execution.

---

### 4. Short-Circuiting Execution (`AuthenticateOperation` Run)

When `-[AuthenticateOperation run]` executes on iOS 7–10:

* The tweak verifies that either the operation or its `authenticationContext` is marked **and** that the context's `promptStyle` is `1000`.
* It then inspects `[self _account]`. If an Apple ID account object is present, it lets the original `run` proceed normally.
* If `_account` is `nil` (meaning the required Apple ID is not logged in on the device), the tweak skips the original `run` method entirely—avoiding both the network authentication failure and any fallback credential prompt—and synthesizes a clean success state on the operation:
* `setAuthenticateResponseWithAccount:nil type:3`
* `setError:nil`
* `setSuccess:YES`



---

### End-to-End Flow Summary

| Stage | Class / Method | Action |
| --- | --- | --- |
| **Load** | `%ctor` | Detects iOS 6 vs. iOS 7–10 and activates the appropriate hooks. |
| **Context Setup** | `-[AuthorizeMachineOperation _newAuthenticationContext]` | Detects `reason == @"refetch"`, sets `promptStyle = 1000`, and (on iOS 7–10) records the DSID and attaches an associated `@YES` flag. |
| **Op Creation** | `-[AuthenticateOperation initWithAuthenticationContext:]` | *(iOS 7–10)* Propagates the `@YES` marker to the operation and its context. |
| **Execution** | `-[AuthenticateOperation run]` | *(iOS 7–10)* If marked, `promptStyle == 1000`, and `_account == nil`, bypasses network/UI auth and reports `success = YES` with `error = nil`. |

---

### Building

The makefile as written assumes Xcode 9.4.1 installed in `/Applications/Xcode.app` and the iOS 8.4 SDK is in your Theos SDKs folder.

As always, use `make package` to build!