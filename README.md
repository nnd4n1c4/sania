# macOS live demo: Firebase iOS findings CV-C58, CV-C59, CV-C60

Live demo of three Firebase iOS findings on a GitHub-hosted macOS runner.
The drafts are CODE-VERIFIED ONLY because the Linux VM that produced them
has no Xcode. This repo holds only the demo tests and the workflow that runs
them; the SDK itself is checked out at the pinned SHA on the runner.

Repo: **nnd4n1c4/sania** (private, by Mart's decision).
SDK: firebase/firebase-ios-sdk, pinned HEAD
`80e0bc6a8a788ee3644586a25aa76ad558411f0a`, version 13.3.0.
Runner: `macos-26` (arm64), Xcode 26.4 selected explicitly (the SDK needs
Xcode 26.2+ / Swift 6.2.3+).

## What each demo proves

All three demos drive the REAL pinned client code against in-test listeners
on 127.0.0.1, with DUMMY tokens only. No live credentials, no live GCP
calls, no Firebase project. A replay client that merely re-sends headers
would prove nothing and is not used anywhere here.

### CV-C58: Database (`demo-tests/CV58DatabaseDemoTests.m`)

Target `DatabaseUnit`, scheme `DatabaseUnit`, run with
`xcodebuild test -only-testing:DatabaseUnit/CV58DatabaseDemoTests`.

- Leg 1: `databaseWithURL:` to a caller host sends the live ID token in the
  websocket auth frame `{a:"auth", b:{cred: <token>}}` on (re)connect.
- Leg 2: the handshake carries the live App Check token in the
  `X-Firebase-AppCheck` header, before any frame exists.
- Leg 3: posting the App Check token-change notification re-sends the token
  as a websocket frame `{a:"appcheck", b:{token: <token>}}`.

The test brings its own websocket server (raw TCP socket, HTTP upgrade,
masked-frame parsing), because no fake websocket server exists in the repo.
The fakes are the repo's own `FIRAuthInteropFake` / `FIRAppCheckFake`,
wired exactly as `FTestHelpers.m:54-64` wires them.

### CV-C60: Functions (`demo-tests/CV60FunctionsDemoTests.swift`)

Target `FirebaseFunctionsUnit`, scheme `FirebaseFunctionsUnit`, run with
`xcodebuild test -only-testing:FirebaseFunctionsUnit/CV60FunctionsDemoTests`.

- Leg 1: `customDomain` is used verbatim; all three tokens (ID, FCM, App
  Check) ride the first request. The https-or-loopback guard passes because
  127.0.0.1 is loopback.
- Leg 2: `httpsCallable(URL:)` is used verbatim; same three headers.
- Leg 3: a 302 hop from the caller host carries all three tokens onto the
  hop target. GTMSessionFetcher's `willPerformHTTPRedirection` copies the
  original request, headers included, and overrides only the URL (verified
  first-hand from the official repo at tag v5.3.1, the latest in the pinned
  4.0.0 to 6.0.0 range).
- Leg 4: a 302 hop on the `stream()` path drops Authorization but keeps the
  FCM and App Check tokens. This rests on Apple URLSession hop behavior, so
  the macOS run is the confirmation.

The test brings its own HTTP listener (`NWListener`). A fresh
`GTMSessionFetcherService` with `allowLocalhostRequest = true` and
`allowedInsecureSchemes = ["http"]` is used, because `makeFetcher` only
sets those flags on the emulator path and `useEmulator` would override
`customDomain`.

### CV-C59: Firestore (`demo-tests/CV59FirestoreDemoTests.cc`)

CMake C++ unit test in `Firestore/core/test/unit/remote/`, picked up
automatically by that directory's CMake glob, so no CMakeLists edit is
needed. Run as `firestore_remote_test --gtest_filter='DemoTokenTest.*'`.

- Leg 2: a plaintext gRPC `Commit` to a caller host
  (`sslEnabled=false`) carries `authorization: Bearer <ID token>` and
  `x-firebase-appcheck` as call metadata.
- Leg 1: a TLS gRPC `Commit` to a caller host carries the same two tokens.
  The server certificate must chain to a system-trusted root, so the
  workflow generates a throwaway test CA, installs it with
  `security add-trusted-cert`, and passes the server cert/key paths via
  `FIRESTORE_DEMO_TLS_CERT` / `FIRESTORE_DEMO_TLS_KEY`. If those variables
  are absent the TLS test skips cleanly; the plaintext leg is unaffected.

The server is an adaptation of the repo's own `TlsLoopbackServer`: same
`grpc::ServerBuilder` + `AsyncGenericService` shape and the same bounded
shutdown workaround, but it records call metadata and finishes every call
with UNIMPLEMENTED instead of echoing. The metadata arrival is the proof.
The credential providers subclass `EmptyCredentialsProvider` and return a
real token value from `GetToken`, the same injection shape the repo's own
`FakeCredentialsProvider` uses, except the token is non-empty.

Why CMake and not the Xcode integration target: the in-process gRPC server
and the fake providers live in `Firestore/core/test/`, which is excluded
from the SPM package and is not part of the Xcode integration target. The
CMake `firestore_remote_test` target already links everything the demo
needs (core, grpc server, gtest).

## Dummy tokens

Only these fixed dummy strings appear in the tests. There are no live
credentials, no API keys, no personal data in this repo:

- ID token: `FAKE-ID-TOKEN-123`
- App Check token: `FAKE-APPCHECK-123` (handshake) / `FAKE-APPCHECK-456` (refresh)
- FCM token: `fakeFCMToken` (the fixed value of `FIRMessagingInteropFake`)

## How to run

Actions tab -> "macOS live demo (CV-C58 / CV-C59 / CV-C60)" -> Run workflow.
Or via API:

```text
POST /repos/nnd4n1c4/sania/actions/workflows/macos-demo.yml/dispatches
{"ref": "main"}
```

## Cost

Standard GitHub-hosted runners are free and unlimited on PUBLIC
repositories. This repo is PRIVATE by Mart's decision, so macOS minutes
bill at 10x against the 2,000 free Actions minutes/month: roughly 200
macOS minutes/month free.

Estimated first cold run: roughly 60 minutes wall for the SPM job plus
60-90 minutes wall for the CMake job, so roughly 1,200-1,500 billed
minutes, which EXCEEDS the free allowance. The run will likely stall or
fail partway once the allowance is exhausted. Subsequent runs reuse the
SwiftPM / DerivedData / ccache caches and are far cheaper (roughly 10-20
minutes wall each).

If the repo is flipped to public (Settings -> Change visibility), the cap
disappears entirely. The repo contains no secrets and nothing sensitive:
only demo tests, a throwaway-CA script, and this workflow.
