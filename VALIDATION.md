# Validation record

Date: 2026-10-26

## Passed locally

- Swift core package compilation using Apple Swift 6.1.2 in Swift 5 language mode.
- Dependency-free core executable: 27 checks passed, 0 failed. This covers SSE
  framing, UTF-8, early streaming delivery, terminal events, resource limits,
  cancellation, request construction, catalog decoding, mocked HTTP responses,
  and conversation persistence.
- KeychainStore and AppSettings type checking against the macOS Foundation,
  Combine and Security frameworks. This is not an iOS Keychain runtime test.
- ChatState type checking using temporary macOS adapters supplied by the UI
  worker. This does not validate SwiftUI or lifecycle behavior on a phone.
- Syntax parsing of all application Swift sources.
- XcodeGen project generation and plist validation, including Privacy Manifest.
- Source review by GPT-6 Astra followed by DeepSeek implementation corrections.
- Source scan found no production gateway keys or private tunnel address.

## Not verified

- The full iOS application has NOT been compiled or run. This Mac has Command
  Line Tools, but no full Xcode installation or iOS SDK.
- XCTest could not run because this toolchain lacks the XCTest module. The
  executable checks are useful but are not a substitute for the entire test suite.
- iOS 27 compatibility, simulator screenshots, accessibility, iPhone/iPad
  navigation, background/lock transitions, and real-device storage protection
  still need verification with a suitable SDK and device/runtime.
- No signed IPA, TestFlight upload, App Store submission or signing setup exists.
- The final Swift client was tested with local mock HTTP fixtures, not against
  a production account. Earlier gateway probing is not an end-to-end app test.

## Scope

This is an unofficial remote chat companion MVP, not an iOS port of Magpie's
provider administration, desktop agent integration, billing dashboard or CLI
runtime. Model selection uses a menu; catalog search and app artwork are deferred.
The deployment target remains iOS 17. Raising it to 27 would not prove compatibility.

Follow README.md for build commands and the manual acceptance checklist before
claiming a supported iOS 27 release.
