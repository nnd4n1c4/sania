# macOS live-demo prep report (CV-C58 / CV-C59 / CV-C60)
Date: 2026-11-19. Repo: nnd4n1c4/sania (private, Mart's decision).
Repo created 2026-11-19 ~14:58 WIB; all 7 staged files pushed and verified
via the repo tree. First run NOT triggered yet (see cost note below).

## Design (10 lines)
1. macos-26 runner, Xcode 26.4 selected explicitly (SDK needs 26.2+).
2. Workflow checks out firebase-ios-sdk at pinned SHA 80e0bc6a (13.3.0).
3. Demo tests are copied into that checkout; the SDK is never edited here.
4. C58 + C60 share one SPM job, one checkout, one build, to save minutes.
5. C59 runs as a CMake C++ unit test, not the Xcode integration target.
6. All listeners run inside the test process on 127.0.0.1, dummy tokens only.
7. C60 leg 3 hop handler verified first-hand at GTMSessionFetcher v5.3.1.
8. C59 TLS leg uses a throwaway CA installed on the runner per run.
9. Workflow is manual only (workflow_dispatch); nothing runs on push.
10. No live credentials, no live GCP calls, no Firebase project anywhere.

## What was verified first-hand (from the pinned tree)
- DatabaseUnit target (Package.swift:679-697); FirebaseFunctionsUnit (:748-761).
- Functions internal init (Functions.swift:343-353); setUp pattern in tests.
- FTestHelpers wiring (configForName, createDatabaseForTests); FIRDatabase_Private.h.
- FWebSocketConnectionTest raw TCP listener precedent; hello + auth + appcheck
  wire format re-read (FPersistentConnection.m, FConnection.m, FConstants.m).
- FSTIntegrationTestCase fakes; FIRFirestore+Internal.h init; Datastore ctor,
  Start(), CommitMutations(), DatabaseInfo fields; FakeCredentialsProvider shape.
- TlsLoopbackServer full shape (ServeLoop state machine, bounded shutdown).
- remote/ CMakeLists uses a glob, so a new .cc file needs no CMake edit.
- Firestore repo CI pattern: macos-26, Xcode_26.4, Pods cache, install_prereqs,
  build.sh Firestore macOS xcodebuild / cmake (mirrored where applicable).
- GTMSessionFetcher v5.3.1 (official repo): willPerformHTTPRedirection copies
  the original request and overrides only the URL; service properties
  allowLocalhostRequest / allowedInsecureSchemes exist.
- GitHub connection verified as nnd4n1c4 (free plan, 0 private repos);
  nnd4n1c4/sania does not exist yet (404), so creation will not collide.
- Workflow YAML parses; all test-file APIs grep-verified against the tree;
  all three target dirs exist in the tree; brace balance OK on all 3 tests;
  staged files contain dummy tokens only (secret scan clean).

## What could NOT be validated locally
- No Swift, no Xcode, no Apple SDKs on this Linux VM; /opt/c49-target is gone.
- No test file was compiled or run. Swift, ObjC, and C++ syntax were checked
  by hand and by brace balance only; a compile error on the runner is
  possible and will show in the Actions log.
- The C59 CMake target build was not run; the binary path is found with
  `find build -name firestore_remote_test` at run time.
- The macos-26 image's exact Xcode list was read from the runner-images
  readme (26.0.1-26.6); the workflow falls back to the newest Xcode 26.x
  if 26.4 is absent, and prints the selected version.

## Known risks (in order)
1. COST (private repo): first cold run is roughly 1,200-1,500 billed minutes
   vs roughly 200 free macOS minutes/month. It will likely exhaust the
   allowance partway. Flipping the repo to public removes the cap entirely.
2. C59 TLS leg: depends on the test CA being trusted by the client's
   default TLS credentials; if verification fails, that leg fails while the
   plaintext leg still proves the class. The TLS test skips cleanly without
   the CA variables, never fakes a pass.
3. C60 leg 4 rests on Apple URLSession hop behavior, not repo code; the
   macOS run is the confirmation.
4. C58 App Check refresh depends on the notification reaching FRepo while
   connected; the test waits 10 s and fails loudly if the frame never comes.
5. First-run SPM/CMake builds are long (roughly 60-90 min per job); the
   workflow timeouts are 120 min (SPM) and 180 min (CMake).

## Open decisions (for Mart)
- Repo name "sania", PRIVATE: decided. Nothing else is open except whether
  to flip it public before the first run (see cost risk 1).
- The first run is NOT triggered automatically; run it from the Actions tab
  or via the dispatch API call in the README.

## Staged files
- demo-tests/CV58DatabaseDemoTests.m (legs 1-3, in-test websocket server)
- demo-tests/CV60FunctionsDemoTests.swift (legs 1-4, in-test HTTP listeners)
- demo-tests/CV59FirestoreDemoTests.cc (legs 1-2, in-process gRPC server)
- scripts/make-firestore-test-ca.sh (throwaway CA + 127.0.0.1 server cert)
- .github/workflows/macos-demo.yml (workflow_dispatch, 2 jobs)
- macos-demo-README.md (design, cost, run instructions)
