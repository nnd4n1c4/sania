/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Live demo for CV-C58 (Firebase iOS Realtime Database): the Database client
// sends the operator live tokens to any caller-supplied databaseURL on the
// first request. Leg 1 is the websocket auth frame carrying the live ID
// token, leg 2 is the X-Firebase-AppCheck header on the websocket handshake,
// leg 3 is the App Check token re-sent as a websocket frame on refresh.
//
// This test drives the REAL pinned Database code (firebase-ios-sdk HEAD
// 80e0bc6a, FirebaseDatabase 13.3.0) against an in-test websocket server on
// 127.0.0.1, with DUMMY tokens only. No live credentials, no live GCP calls,
// no Firebase project. The fakes are the repo's own SharedTestUtilities
// fakes, wired through FTestHelpers' established pattern
// (FirebaseDatabase/Tests/Helpers/FTestHelpers.m:54-64): a
// FIRDatabaseConnectionContextProvider built from the fakes, wrapped in a
// FIRDatabaseConfig, then [FIRDatabase createDatabaseForTests:].
//
// Dummy tokens used below:
//   ID token:      FAKE-ID-TOKEN-123
//   App Check:     FAKE-APPCHECK-123 (handshake) / FAKE-APPCHECK-456 (refresh)
//   FCM token:     none (Database sends no FCM token)

#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>

#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FirebaseCore/Extension/FirebaseCoreInternal.h"
#import "FirebaseDatabase/Sources/Api/Private/FIRDatabase_Private.h"
#import "FirebaseDatabase/Sources/Constants/FConstants.h"
#import "FirebaseDatabase/Sources/FIRDatabaseConfig_Private.h"
#import "FirebaseDatabase/Sources/Utilities/FUtilities.h"
#import "SharedTestUtilities/AppCheckFake/FIRAppCheckFake.h"
#import "SharedTestUtilities/AppCheckFake/FIRAppCheckTokenResultFake.h"
#import "SharedTestUtilities/FIRAuthInteropFake.h"

static NSString *const kDemoIDToken = @"FAKE-ID-TOKEN-123";
static NSString *const kDemoAppCheckToken = @"FAKE-APPCHECK-123";
static NSString *const kDemoAppCheckRefreshedToken = @"FAKE-APPCHECK-456";
static NSString *const kWebSocketGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// MARK: - Minimal in-test websocket server

// Accepts one TCP connection on 127.0.0.1, speaks the HTTP upgrade and the
// websocket framing the RTDB client needs: reads masked client frames
// (7-bit / 126 / 127 lengths, continuation, ping/pong, close), sends the
// RTDB hello, and auto-replies {"s":"ok"} to every data request it sees so
// the client reaches Connected. No fake server exists in the repo's tests;
// the only precedent is the raw TCP listener in
// FirebaseDatabase/Tests/Unit/FWebSocketConnectionTest.m:185-236.
@interface DemoWebSocketServer : NSObject

@property(nonatomic, readonly) int port;
@property(nonatomic, copy) void (^onMessageReceived)(NSDictionary *message);
@property(nonatomic, copy) void (^onHandshakeComplete)(NSDictionary *headers);

@property(nonatomic, strong) NSDictionary *handshakeHeaders;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *receivedMessages;

- (instancetype)init;
- (void)start;
- (void)stop;

@end

@implementation DemoWebSocketServer {
  int _serverSocket;
  int _clientSocket;
  dispatch_queue_t _queue;
  BOOL _stopped;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _receivedMessages = [NSMutableArray array];
    _serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    NSAssert(_serverSocket >= 0, @"socket failed");
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;  // ephemeral
    NSAssert(bind(_serverSocket, (struct sockaddr *)&address, sizeof(address)) == 0, @"bind failed");
    NSAssert(listen(_serverSocket, 1) == 0, @"listen failed");
    socklen_t addressLength = sizeof(address);
    NSAssert(getsockname(_serverSocket, (struct sockaddr *)&address, &addressLength) == 0,
             @"getsockname failed");
    _port = ntohs(address.sin_port);
    _queue = dispatch_queue_create("demo.websocket.server", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)start {
  __weak DemoWebSocketServer *weakSelf = self;
  dispatch_async(_queue, ^{
    [weakSelf runSession];
  });
}

- (void)stop {
  _stopped = YES;
  if (_clientSocket > 0) {
    close(_clientSocket);
    _clientSocket = 0;
  }
  if (_serverSocket > 0) {
    close(_serverSocket);
    _serverSocket = 0;
  }
}

- (void)dealloc {
  [self stop];
}

// Reads exactly `length` bytes or nil on timeout/close.
- (NSData *)readExact:(NSUInteger)length timeout:(NSTimeInterval)timeout {
  NSMutableData *data = [NSMutableData dataWithCapacity:length];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (data.length < length) {
    NSTimeInterval remaining = [deadline timeIntervalSinceNow];
    if (remaining <= 0 || _stopped) {
      return nil;
    }
    struct pollfd pfd = {.fd = _clientSocket, .events = POLLIN};
    int ready = poll(&pfd, 1, (int)(remaining * 1000));
    if (ready <= 0) {
      return nil;
    }
    uint8_t buffer[8192];
    NSUInteger want = MIN(sizeof(buffer), length - data.length);
    ssize_t n = read(_clientSocket, buffer, want);
    if (n <= 0) {
      return nil;
    }
    [data appendBytes:buffer length:(NSUInteger)n];
  }
  return data;
}

- (BOOL)writeData:(NSData *)data {
  const uint8_t *bytes = data.bytes;
  NSUInteger remaining = data.length;
  while (remaining > 0) {
    ssize_t n = write(_clientSocket, bytes, remaining);
    if (n <= 0) {
      return NO;
    }
    bytes += n;
    remaining -= (NSUInteger)n;
  }
  return YES;
}

// Sends one unmasked text frame.
- (void)sendText:(NSString *)text {
  NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *frame = [NSMutableData data];
  uint8_t first = 0x80 | 0x01;  // FIN + text
  [frame appendBytes:&first length:1];
  if (payload.length < 126) {
    uint8_t second = (uint8_t)payload.length;
    [frame appendBytes:&second length:1];
  } else if (payload.length < 65536) {
    uint8_t second = 126;
    uint16_t length = htons((uint16_t)payload.length);
    [frame appendBytes:&second length:1];
    [frame appendBytes:&length length:2];
  } else {
    uint8_t second = 127;
    uint64_t length = CFSwapInt64HostToBig((uint64_t)payload.length);
    [frame appendBytes:&second length:1];
    [frame appendBytes:&length length:8];
  }
  [frame appendData:payload];
  [self writeData:frame];
}

// Sends one unmasked pong frame with the ping payload.
- (void)sendPong:(NSData *)payload {
  NSMutableData *frame = [NSMutableData data];
  uint8_t first = 0x80 | 0x0A;  // FIN + pong
  [frame appendBytes:&first length:1];
  uint8_t second = (uint8_t)payload.length;
  [frame appendBytes:&second length:1];
  [frame appendData:payload];
  [self writeData:frame];
}

- (void)runSession {
  struct pollfd pfd = {.fd = _serverSocket, .events = POLLIN};
  if (poll(&pfd, 1, 15000) <= 0) {
    return;
  }
  _clientSocket = accept(_serverSocket, NULL, NULL);
  if (_clientSocket < 0) {
    return;
  }

  // Read the HTTP upgrade request up to \r\n\r\n.
  NSMutableData *requestData = [NSMutableData data];
  while (YES) {
    NSData *chunk = [self readExact:1 timeout:15];
    if (!chunk) {
      return;
    }
    [requestData appendData:chunk];
    if (requestData.length >= 4) {
      NSData *tail = [requestData subdataWithRange:NSMakeRange(requestData.length - 4, 4)];
      if (memcmp(tail.bytes, "\r\n\r\n", 4) == 0) {
        break;
      }
    }
    if (requestData.length > 16384) {
      return;
    }
  }
  NSString *requestText = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
  if (!requestText) {
    return;
  }
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  NSString *key = nil;
  for (NSString *line in [requestText componentsSeparatedByString:@"\r\n"]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location != NSNotFound) {
      NSString *name = [[line substringToIndex:colon.location]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSString *value = [[line substringFromIndex:colon.location + 1]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      headers[name.lowercaseString] = value;
      if ([name.lowercaseString isEqualToString:@"sec-websocket-key"]) {
        key = value;
      }
    }
  }
  self.handshakeHeaders = headers;
  if (self.onHandshakeComplete) {
    self.onHandshakeComplete(headers);
  }
  if (!key) {
    return;
  }

  // 101 Switching Protocols.
  NSString *acceptSource = [key stringByAppendingString:kWebSocketGUID];
  NSData *acceptData = [acceptSource dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1(acceptData.bytes, (CC_LONG)acceptData.length, digest);
  NSString *accept = [[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH]
      base64EncodedStringWithOptions:0];
  NSString *response = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\n"
                                                   @"Upgrade: websocket\r\n"
                                                   @"Connection: Upgrade\r\n"
                                                   @"Sec-WebSocket-Accept: %@\r\n\r\n",
                                                   accept];
  if (![self writeData:[response dataUsingEncoding:NSUTF8StringEncoding]]) {
    return;
  }

  // RTDB hello. No "h" host field: a hello carrying "h" overwrites
  // repoInfo.internalHost (FConnection.m:256-259). The timestamp must be a
  // number or onHandshake closes the connection.
  long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
  [self sendText:[NSString stringWithFormat:@"{\"t\":\"c\",\"d\":{\"t\":\"h\",\"d\":{\"ts\":%lld}}}", ms]];

  // Frame loop.
  NSMutableData *fragments = nil;
  NSInteger segmentsRemaining = 0;
  NSMutableData *segmented = nil;
  while (!_stopped) {
    NSData *header = [self readExact:2 timeout:30];
    if (!header) {
      return;
    }
    const uint8_t *h = header.bytes;
    BOOL fin = (h[0] & 0x80) != 0;
    uint8_t opcode = h[0] & 0x0F;
    BOOL masked = (h[1] & 0x80) != 0;
    uint64_t length = h[1] & 0x7F;
    if (length == 126) {
      NSData *ext = [self readExact:2 timeout:15];
      if (!ext) return;
      uint16_t v;
      memcpy(&v, ext.bytes, 2);
      length = ntohs(v);
    } else if (length == 127) {
      NSData *ext = [self readExact:8 timeout:15];
      if (!ext) return;
      uint64_t v;
      memcpy(&v, ext.bytes, 8);
      length = CFSwapInt64BigToHost(v);
    }
    uint8_t maskKey[4] = {0, 0, 0, 0};
    if (masked) {
      NSData *mask = [self readExact:4 timeout:15];
      if (!mask) return;
      memcpy(maskKey, mask.bytes, 4);
    }
    NSData *payload = [self readExact:(NSUInteger)length timeout:30];
    if (!payload) {
      return;
    }
    NSMutableData *unmasked = [payload mutableCopy];
    if (masked) {
      uint8_t *bytes = unmasked.mutableBytes;
      for (NSUInteger i = 0; i < unmasked.length; i++) {
        bytes[i] ^= maskKey[i % 4];
      }
    }
    if (opcode == 0x9) {  // ping
      [self sendPong:unmasked];
      continue;
    }
    if (opcode == 0x8) {  // close
      return;
    }
    if (opcode == 0x0) {  // continuation
      if (fragments) {
        [fragments appendData:unmasked];
      }
    } else if (opcode == 0x1) {  // text
      fragments = [unmasked mutableCopy];
    } else {
      continue;
    }
    if (!fin) {
      continue;
    }
    NSString *text = [[NSString alloc] initWithData:fragments encoding:NSUTF8StringEncoding];
    fragments = nil;
    if (!text) {
      continue;
    }
    // The client splits messages over 16384 bytes into segments prefixed by
    // a bare-number count frame (FWebSocketConnection.m:260-289). Auth and
    // appcheck frames are tiny single frames; reassemble if a count shows up.
    if (segmentsRemaining > 0) {
      [segmented appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
      segmentsRemaining--;
      if (segmentsRemaining > 0) {
        continue;
      }
      text = [[NSString alloc] initWithData:segmented encoding:NSUTF8StringEncoding];
      segmented = nil;
    } else {
      NSInteger count = 0;
      NSScanner *scanner = [NSScanner scannerWithString:text];
      if ([scanner scanInteger:&count] && scanner.atEnd && count > 0) {
        segmentsRemaining = count;
        segmented = [NSMutableData data];
        continue;
      }
    }
    // Ignore the "0" keepalive text frame (every 45 s).
    if ([text isEqualToString:@"0"]) {
      continue;
    }
    NSData *jsonData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:jsonData
                                                            options:0
                                                              error:nil];
    if (![message isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    @synchronized(self) {
      [self.receivedMessages addObject:message];
    }
    if (self.onMessageReceived) {
      self.onMessageReceived(message);
    }
    // Auto-reply ok to data requests so the client reaches Connected.
    NSDictionary *d = message[@"d"];
    NSNumber *r = d[@"r"];
    if (r) {
      NSString *reply = [NSString
          stringWithFormat:@"{\"t\":\"d\",\"d\":{\"r\":%@,\"b\":{\"s\":\"ok\",\"d\":{}}}}", r];
      [self sendText:reply];
    }
  }
}

@end

// MARK: - Demo tests

@interface CV58DatabaseDemoTests : XCTestCase
@end

@implementation CV58DatabaseDemoTests

- (FIRDatabase *)databaseWithServer:(DemoWebSocketServer *)server
                           authFake:(FIRAuthInteropFake *)authFake
                       appCheckFake:(FIRAppCheckFake *)appCheckFake {
  id<FIRDatabaseConnectionContextProvider> contextProvider =
      [FIRDatabaseConnectionContextProvider contextProviderWithAuth:authFake appCheck:appCheckFake];
  FIRDatabaseConfig *config =
      [[FIRDatabaseConfig alloc] initWithSessionIdentifier:@"cv58-demo"
                                               googleAppID:@"fake-app-id"
                                           contextProvider:contextProvider];
  NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%d", server.port];
  FParsedUrl *parsedUrl = [FUtilities parseUrl:urlString];
  return [FIRDatabase createDatabaseForTests:parsedUrl.repoInfo config:config];
}

// Legs 1 + 2: the websocket auth frame carries the live ID token, and the
// handshake carries the live App Check token in X-Firebase-AppCheck.
- (void)testLeg1AndLeg2 {
  DemoWebSocketServer *server = [[DemoWebSocketServer alloc] init];
  [server start];
  addTeardownBlock(^{
    [server stop];
  });

  FIRAuthInteropFake *authFake =
      [[FIRAuthInteropFake alloc] initWithToken:kDemoIDToken userID:@"fake-uid" error:nil];
  FIRAppCheckFake *appCheckFake = [[FIRAppCheckFake alloc] init];
  appCheckFake.tokenResult =
      [[FIRAppCheckTokenResultFake alloc] initWithToken:kDemoAppCheckToken error:nil];

  XCTestExpectation *authExpectation = [self expectationWithDescription:@"auth frame received"];
  __block NSDictionary *authFrame = nil;
  server.onMessageReceived = ^(NSDictionary *message) {
    NSDictionary *d = message[@"d"];
    if ([d[@"a"] isEqualToString:@"auth"]) {
      authFrame = message;
      [authExpectation fulfill];
    }
  };

  // Creating the database opens the connection (FRepo deferredInit).
  FIRDatabase *database = [self databaseWithServer:server authFake:authFake appCheckFake:appCheckFake];
  XCTAssertNotNil(database);

  [self waitForExpectations:@[ authExpectation ] timeout:15];

  // Leg 2: the App Check token rode the handshake, before any frame existed.
  XCTAssertEqualObjects(server.handshakeHeaders[@"x-firebase-appcheck"], kDemoAppCheckToken);
  // Leg 1: the auth frame carries the live ID token.
  XCTAssertEqualObjects(authFrame[@"d"][@"a"], @"auth");
  XCTAssertEqualObjects(authFrame[@"d"][@"b"][@"cred"], kDemoIDToken);
}

// Leg 3: the App Check token is re-sent as a websocket frame on refresh.
- (void)testLeg3AppCheckFrameOnRefresh {
  DemoWebSocketServer *server = [[DemoWebSocketServer alloc] init];
  [server start];
  addTeardownBlock(^{
    [server stop];
  });

  FIRAuthInteropFake *authFake =
      [[FIRAuthInteropFake alloc] initWithToken:kDemoIDToken userID:@"fake-uid" error:nil];
  FIRAppCheckFake *appCheckFake = [[FIRAppCheckFake alloc] init];
  appCheckFake.tokenResult =
      [[FIRAppCheckTokenResultFake alloc] initWithToken:kDemoAppCheckToken error:nil];

  XCTestExpectation *authExpectation = [self expectationWithDescription:@"auth frame received"];
  XCTestExpectation *appCheckExpectation =
      [self expectationWithDescription:@"appcheck frame received"];
  __block NSDictionary *appCheckFrame = nil;
  server.onMessageReceived = ^(NSDictionary *message) {
    NSDictionary *d = message[@"d"];
    if ([d[@"a"] isEqualToString:@"auth"]) {
      [authExpectation fulfill];
    } else if ([d[@"a"] isEqualToString:@"appcheck"]) {
      appCheckFrame = message;
      [appCheckExpectation fulfill];
    }
  };

  FIRDatabase *database = [self databaseWithServer:server authFake:authFake appCheckFake:appCheckFake];
  XCTAssertNotNil(database);

  [self waitForExpectations:@[ authExpectation ] timeout:15];
  // Let the client process the server's ok reply and reach Connected; the
  // refresh frame is only sent while connected (FPersistentConnection.m:1407).
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

  // Trigger the refresh exactly as the repo's own test does
  // (FIRDatabaseConnectionContextProviderTests.m:250-270).
  [[NSNotificationCenter defaultCenter]
      postNotificationName:[appCheckFake tokenDidChangeNotificationName]
                    object:appCheckFake
                  userInfo:@{
                    [appCheckFake notificationTokenKey] : kDemoAppCheckRefreshedToken,
                    [appCheckFake notificationAppNameKey] : @"app_name",
                  }];

  [self waitForExpectations:@[ appCheckExpectation ] timeout:10];

  XCTAssertEqualObjects(appCheckFrame[@"d"][@"a"], @"appcheck");
  XCTAssertEqualObjects(appCheckFrame[@"d"][@"b"][@"token"], kDemoAppCheckRefreshedToken);
}

@end
