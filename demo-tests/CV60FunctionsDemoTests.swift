// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Live demo for CV-C60 (Firebase iOS Functions): the Functions client sends
// the operator live tokens to any caller-supplied custom domain or function
// URL on the first request, and the fetcher carries all three tokens onto a
// hop target.
//
// This test drives the REAL pinned Functions code (firebase-ios-sdk HEAD
// 80e0bc6a, FirebaseFunctions 13.3.0) against in-test HTTP listeners on
// 127.0.0.1, with DUMMY tokens only. No live credentials, no live GCP calls,
// no Firebase project. The fakes are the repo's own SharedTestUtilities
// fakes, wired through the internal init exactly as FunctionsTests.swift
// does (Functions.swift:343-353).
//
// Dummy tokens used below:
//   ID token:      FAKE-ID-TOKEN-123
//   App Check:     FAKE-APPCHECK-123
//   FCM token:     fakeFCMToken (fixed value of FIRMessagingInteropFake)

import Foundation
import Network

import FirebaseCore
@testable import FirebaseFunctions
#if COCOAPODS
  import GTMSessionFetcher
#else
  import GTMSessionFetcherCore
#endif

import SharedTestUtilities
import XCTest

// MARK: - Minimal in-test HTTP listener

/// A tiny HTTP/1.1 listener on 127.0.0.1 that records every request it sees
/// and answers from a handler closure. One request per connection
/// (responds with `Connection: close`).
final class DemoHTTPListener {
  struct CapturedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  typealias Handler = (CapturedRequest) -> (status: Int, headers: [String: String], body: Data)

  private let listener: NWListener
  private let queue = DispatchQueue(label: "demo.http.listener")
  private let lock = NSLock()
  private(set) var requests: [CapturedRequest] = []
  var onRequest: ((CapturedRequest) -> Void)?
  var handler: Handler

  init(handler: @escaping Handler) throws {
    self.handler = handler
    listener = try NWListener(using: .tcp, on: .any)
  }

  var port: UInt16 { listener.port?.rawValue ?? 0 }

  func start() {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection: connection)
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 10)
  }

  func stop() {
    listener.cancel()
  }

  private func record(_ request: CapturedRequest) {
    lock.lock()
    requests.append(request)
    lock.unlock()
    onRequest?(request)
  }

  private func handle(connection: NWConnection) {
    connection.start(queue: queue)
    var buffer = Data()
    func receiveNext() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
        guard let self else { return }
        if let data, !data.isEmpty { buffer.append(data) }
        if error != nil {
          connection.cancel()
          return
        }
        guard let request = Self.parse(buffer: buffer) else {
          // Not a complete request yet; keep reading.
          receiveNext()
          return
        }
        self.record(request)
        let (status, headers, body) = self.handler(request)
        var response = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        response += "Content-Type: \(headers["Content-Type"] ?? "application/json")\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        for (key, value) in headers where key != "Content-Type" {
          response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
          connection.cancel()
        })
      }
    }
    receiveNext()
  }

  private static func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 302: return "Found"
    default: return "Status"
    }
  }

  /// Parses one complete HTTP request from the buffer, or nil if incomplete.
  private static func parse(buffer: Data) -> CapturedRequest? {
    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let headerData = buffer.subdata(in: buffer.startIndex ..< headerEnd.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    var contentLength = 0
    for line in lines.dropFirst() {
      let kv = line.split(separator: ":", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = kv[1].trimmingCharacters(in: .whitespaces)
      headers[key] = value
      if key == "content-length" { contentLength = Int(value) ?? 0 }
    }
    let bodyStart = headerEnd.upperBound
    guard buffer.count >= bodyStart + contentLength else { return nil }
    let body = buffer.subdata(in: bodyStart ..< bodyStart + contentLength)
    return CapturedRequest(
      method: String(parts[0]),
      path: String(parts[1]),
      headers: headers,
      body: body
    )
  }
}

// MARK: - Demo tests

final class CV60FunctionsDemoTests: XCTestCase {
  static let idToken = "FAKE-ID-TOKEN-123"
  static let appCheckToken = "FAKE-APPCHECK-123"
  // FIRMessagingInteropFake returns this fixed FCM token; it is not settable.
  static let fcmToken = "fakeFCMToken"

  private func makeFunctions(customDomain: String?,
                             fetcherService: GTMSessionFetcherService) -> Functions {
    let authFake = FIRAuthInteropFake(token: Self.idToken, userID: "fake-uid", error: nil)
    let appCheckFake = FIRAppCheckFake()
    appCheckFake.tokenResult = FIRAppCheckTokenResultFake(token: Self.appCheckToken, error: nil)
    let messagingFake = FIRMessagingInteropFake()
    return Functions(
      projectID: "demo-project",
      region: "us-central1",
      customDomain: customDomain,
      auth: authFake,
      messaging: messagingFake,
      appCheck: appCheckFake,
      fetcherService: fetcherService
    )
  }

  /// A fresh fetcher service with loopback http allowed, no testBlock.
  /// makeFetcher only sets these flags on the emulator path
  /// (Functions.swift:647-648), so a customDomain demo must set them here.
  private func makeService() -> GTMSessionFetcherService {
    let service = GTMSessionFetcherService()
    service.allowLocalhostRequest = true
    service.allowedInsecureSchemes = ["http"]
    return service
  }

  private func okJSON() -> Data { Data("{\"result\":\"ok\"}".utf8) }

  private func assertTokens(_ request: DemoHTTPListener.CapturedRequest,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
    XCTAssertEqual(request.headers["authorization"], "Bearer \(Self.idToken)", file: file, line: line)
    XCTAssertEqual(request.headers["firebase-instance-id-token"], Self.fcmToken, file: file, line: line)
    XCTAssertEqual(request.headers["x-firebase-appcheck"], Self.appCheckToken, file: file, line: line)
  }

  // Leg 1: customDomain is used verbatim and all three live tokens ride the
  // first request. The https-or-loopback guard passes because 127.0.0.1 is
  // loopback (Functions.swift:780-789).
  func testLeg1CustomDomain() async throws {
    let listener = try DemoHTTPListener { _ in (200, [:], self.okJSON()) }
    listener.start()
    defer { listener.stop() }
    let seen = expectation(description: "listener saw the call")
    listener.onRequest = { _ in seen.fulfill() }

    let functions = makeFunctions(customDomain: "http://127.0.0.1:\(listener.port)",
                                  fetcherService: makeService())
    let callTask = Task { try await functions.httpsCallable("demoFn").call() }
    await fulfillment(of: [seen], timeout: 15)
    guard let request = listener.requests.first else {
      callTask.cancel()
      return XCTFail("Listener saw no request")
    }
    XCTAssertEqual(request.path, "/demoFn")
    assertTokens(request)
    let result = try await callTask.value
    XCTAssertEqual(result.data as? String, "ok")
  }

  // Leg 2: httpsCallable(URL:) is used verbatim and all three live tokens
  // ride the first request.
  func testLeg2CallableURL() async throws {
    let listener = try DemoHTTPListener { _ in (200, [:], self.okJSON()) }
    listener.start()
    defer { listener.stop() }
    let seen = expectation(description: "listener saw the call")
    listener.onRequest = { _ in seen.fulfill() }

    let functions = makeFunctions(customDomain: nil, fetcherService: makeService())
    let url = URL(string: "http://127.0.0.1:\(listener.port)/fn")!
    let callTask = Task { try await functions.httpsCallable(url).call() }
    await fulfillment(of: [seen], timeout: 15)
    guard let request = listener.requests.first else {
      callTask.cancel()
      return XCTFail("Listener saw no request")
    }
    XCTAssertEqual(request.path, "/fn")
    assertTokens(request)
    let result = try await callTask.value
    XCTAssertEqual(result.data as? String, "ok")
  }

  // Leg 3: a 302 hop from the caller host carries all three tokens onto the
  // hop target. GTMSessionFetcher's willPerformHTTPRedirection copies the
  // original request, headers included, and overrides only the URL
  // (GTMSessionFetcher.m, v5.3.1, verified first-hand from the official repo).
  func testLeg3FetcherHop() async throws {
    let second = try DemoHTTPListener { _ in (200, [:], self.okJSON()) }
    second.start()
    defer { second.stop() }
    let first = try DemoHTTPListener { _ in
      (302, ["Location": "http://127.0.0.1:\(second.port)/fn"], Data())
    }
    first.start()
    defer { first.stop() }
    let seenSecond = expectation(description: "second listener saw the hopped call")
    second.onRequest = { _ in seenSecond.fulfill() }

    let functions = makeFunctions(customDomain: "http://127.0.0.1:\(first.port)",
                                  fetcherService: makeService())
    let callTask = Task { try await functions.httpsCallable("demoFn").call() }
    await fulfillment(of: [seenSecond], timeout: 15)
    guard let request = second.requests.first else {
      callTask.cancel()
      return XCTFail("Second listener saw no request")
    }
    XCTAssertEqual(request.path, "/fn")
    assertTokens(request)
    let result = try await callTask.value
    XCTAssertEqual(result.data as? String, "ok")
  }

  // Leg 4: a 302 hop on the stream path drops Authorization but keeps the
  // FCM and App Check tokens. stream() uses URLSession.shared.bytes(for:)
  // (Functions.swift:419-448); URLSession strips Authorization on a hop
  // while copying custom headers. This rests on Apple URLSession hop
  // behavior, so the macOS run is the confirmation.
  @available(macOS 12.0, *)
  func testLeg4StreamHop() async throws {
    let sse = Data("data: {\"result\":\"ok\"}\n\n".utf8)
    let second = try DemoHTTPListener { _ in
      (200, ["Content-Type": "text/event-stream"], sse)
    }
    second.start()
    defer { second.stop() }
    let first = try DemoHTTPListener { _ in
      (302, ["Location": "http://127.0.0.1:\(second.port)/fn"], Data())
    }
    first.start()
    defer { first.stop() }
    let seenSecond = expectation(description: "second listener saw the hopped stream")
    second.onRequest = { _ in seenSecond.fulfill() }

    let functions = makeFunctions(customDomain: nil, fetcherService: makeService())
    let url = URL(string: "http://127.0.0.1:\(first.port)/fn")!
    let streamTask = Task {
      do {
        for try await _ in functions.httpsCallable(url).stream() {}
      } catch {
        // Stream errors after the headers were captured do not matter here.
      }
    }
    await fulfillment(of: [seenSecond], timeout: 15)
    guard let request = second.requests.first else {
      streamTask.cancel()
      return XCTFail("Second listener saw no request")
    }
    XCTAssertEqual(request.path, "/fn")
    XCTAssertNil(request.headers["authorization"], "Authorization must be dropped on a stream hop")
    XCTAssertEqual(request.headers["firebase-instance-id-token"], Self.fcmToken)
    XCTAssertEqual(request.headers["x-firebase-appcheck"], Self.appCheckToken)
    streamTask.cancel()
  }
}
