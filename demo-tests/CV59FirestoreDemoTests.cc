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

// Live demo for CV-C59 (Firebase iOS Firestore): the Firestore client sends
// the operator live tokens to any caller-supplied settings.host on the first
// request, over gRPC. Leg 1 is a TLS call to a caller host, leg 2 is a
// plaintext call (sslEnabled=false) to a caller host.
//
// This test drives the REAL pinned Firestore core (firebase-ios-sdk HEAD
// 80e0bc6a, FirebaseFirestore 13.3.0) against an in-process gRPC server on
// 127.0.0.1, with DUMMY tokens only. No live credentials, no live GCP calls,
// no Firebase project. It lives in Firestore/core/test/unit/remote/ and is
// picked up automatically by that directory's CMake glob
// (firebase_ios_glob(sources *.cc *.h)), so no CMakeLists edit is needed.
//
// The server is a small adaptation of the repo's own TlsLoopbackServer
// (Firestore/core/test/unit/remote/grpc_tls_credentials_provider_apple_test.mm):
// same grpc::ServerBuilder + AsyncGenericService shape and the same bounded
// shutdown workaround, but it records the call metadata and finishes every
// call with UNIMPLEMENTED instead of echoing. The metadata arrival is the
// proof; the UNIMPLEMENTED status is by design.
//
// The credential providers subclass EmptyCredentialsProvider and override
// GetToken to return a real token value, the same injection shape the repo's
// own FakeCredentialsProvider uses, except the token is non-empty:
//   ID token:   FAKE-ID-TOKEN-123
//   App Check:  FAKE-APPCHECK-123
//
// Leg 1 (TLS) needs a server certificate chaining to a system-trusted root.
// The workflow generates a throwaway test CA, installs it with
// `security add-trusted-cert`, and passes the server cert/key paths via
// FIRESTORE_DEMO_TLS_CERT / FIRESTORE_DEMO_TLS_KEY. If those variables are
// absent the TLS test skips cleanly; the plaintext leg is unaffected.

#include "Firestore/core/src/remote/datastore.h"

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "Firestore/core/src/core/database_info.h"
#include "Firestore/core/src/credentials/auth_token.h"
#include "Firestore/core/src/credentials/credentials_fwd.h"
#include "Firestore/core/src/credentials/credentials_provider.h"
#include "Firestore/core/src/credentials/empty_credentials_provider.h"
#include "Firestore/core/src/credentials/user.h"
#include "Firestore/core/src/model/database_id.h"
#include "Firestore/core/src/remote/firebase_metadata_provider_noop.h"
#include "Firestore/core/src/util/async_queue.h"
#include "Firestore/core/src/util/status.h"
#include "Firestore/core/src/util/warnings.h"
#include "Firestore/core/test/unit/remote/create_noop_connectivity_monitor.h"
#include "Firestore/core/test/unit/testutil/async_testing.h"
#include "absl/strings/str_cat.h"
#include "gtest/gtest.h"

SUPPRESS_DOCUMENTATION_WARNINGS_BEGIN()
#include "grpcpp/security/server_credentials.h"
#include "grpcpp/server.h"
#include "grpcpp/server_builder.h"
#include "grpcpp/generic/async_generic_service.h"
#include "grpcpp/support/byte_buffer.h"
#include "grpcpp/support/status.h"
SUPPRESS_END()

namespace firebase {
namespace firestore {
namespace remote {

namespace {

using core::DatabaseInfo;
using credentials::AppCheckCredentialsProvider;
using credentials::AuthCredentialsProvider;
using credentials::AuthToken;
using credentials::User;
using model::DatabaseId;
using util::AsyncQueue;
using util::Status;

constexpr const char* kDemoIDToken = "FAKE-ID-TOKEN-123";
constexpr const char* kDemoAppCheckToken = "FAKE-APPCHECK-123";

// Bounded shutdown: on Apple, grpc::Server::Shutdown() has been observed to
// never return after the server completed handshakes (see TlsLoopbackServer).
// Shut down on a detached thread and leak on timeout instead of hanging.
constexpr std::chrono::seconds kServerShutdownTimeout(15);

std::string ReadFileOrEmpty(const char* path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return "";
  return std::string(std::istreambuf_iterator<char>(in),
                     std::istreambuf_iterator<char>());
}

struct RecordedCall {
  std::string method;
  std::multimap<std::string, std::string> metadata;
};

// In-process generic gRPC server that records the metadata of every call
// and finishes it with UNIMPLEMENTED.
class RecordingLoopbackServer {
 public:
  explicit RecordingLoopbackServer(
      std::shared_ptr<grpc::ServerCredentials> credentials)
      : impl_(std::make_shared<Impl>(this, std::move(credentials))) {
  }

  ~RecordingLoopbackServer() {
    ShutdownBounded(std::move(impl_));
  }

  RecordingLoopbackServer(const RecordingLoopbackServer&) = delete;
  RecordingLoopbackServer& operator=(const RecordingLoopbackServer&) = delete;

  bool started() const {
    return impl_->started();
  }

  int port() const {
    return impl_->port();
  }

  std::string target() const {
    return absl::StrCat("127.0.0.1:", impl_->port());
  }

  // Blocks until at least one call is recorded, or the timeout expires.
  bool WaitForCall(std::chrono::seconds timeout) {
    std::unique_lock<std::mutex> lock(mu_);
    return cv_.wait_for(lock, timeout,
                        [&] { return !calls_.empty(); });
  }

  std::vector<RecordedCall> calls() {
    std::lock_guard<std::mutex> lock(mu_);
    return calls_;
  }

 private:
  class Impl {
   public:
    Impl(RecordingLoopbackServer* outer,
         std::shared_ptr<grpc::ServerCredentials> credentials)
        : outer_(outer) {
      grpc::ServerBuilder builder;
      builder.AddListeningPort("127.0.0.1:0", std::move(credentials), &port_);
      builder.RegisterAsyncGenericService(&generic_service_);
      cq_ = builder.AddCompletionQueue();
      server_ = builder.BuildAndStart();
      if (server_ != nullptr && port_ > 0) {
        server_thread_ = std::thread([this] { ServeLoop(); });
      }
    }

    void Shutdown() {
      if (server_ != nullptr) {
        server_->Shutdown(std::chrono::system_clock::now() +
                          std::chrono::seconds(1));
      }
      {
        std::lock_guard<std::mutex> lock(mu_);
        shutting_down_ = true;
        if (cq_ != nullptr) {
          cq_->Shutdown();
        }
      }
      if (server_thread_.joinable()) {
        server_thread_.join();
      }
    }

    bool started() const {
      return server_ != nullptr && port_ > 0;
    }

    int port() const {
      return port_;
    }

   private:
    enum class Step { kRequest, kRead, kWriteAndFinish };

    struct CallState {
      grpc::GenericServerContext ctx;
      grpc::GenericServerAsyncReaderWriter stream{&ctx};
      grpc::ByteBuffer request;
      Step step = Step::kRequest;
    };

    void SpawnCall() {
      std::lock_guard<std::mutex> lock(mu_);
      if (shutting_down_) {
        return;
      }
      auto* state = new CallState();
      generic_service_.RequestCall(&state->ctx, &state->stream, cq_.get(),
                                   cq_.get(), state);
    }

    void RecordCall(const grpc::GenericServerContext& ctx) {
      RecordedCall call;
      call.method = ctx.method();
      for (const auto& entry : ctx.client_metadata()) {
        call.metadata.emplace(std::string(entry.first.data(), entry.first.size()),
                              std::string(entry.second.data(), entry.second.size()));
      }
      {
        std::lock_guard<std::mutex> lock(outer_->mu_);
        outer_->calls_.push_back(std::move(call));
      }
      outer_->cv_.notify_all();
    }

    void ServeLoop() {
      SpawnCall();
      void* tag = nullptr;
      bool ok = false;
      while (cq_->Next(&tag, &ok)) {
        auto* state = static_cast<CallState*>(tag);
        if (!ok) {
          delete state;
          continue;
        }
        switch (state->step) {
          case Step::kRequest: {
            SpawnCall();
            {
              std::lock_guard<std::mutex> lock(mu_);
              if (shutting_down_) {
                delete state;
                break;
              }
            }
            RecordCall(state->ctx);
            state->step = Step::kRead;
            state->stream.Read(&state->request, state);
            break;
          }
          case Step::kRead: {
            {
              std::lock_guard<std::mutex> lock(mu_);
              if (shutting_down_) {
                delete state;
                break;
              }
            }
            state->step = Step::kWriteAndFinish;
            state->stream.WriteAndFinish(
                grpc::ByteBuffer{}, grpc::WriteOptions{},
                grpc::Status(grpc::StatusCode::UNIMPLEMENTED,
                             "demo: not implemented"),
                state);
            break;
          }
          case Step::kWriteAndFinish:
            delete state;
            break;
        }
      }
    }

    int port_ = 0;
    grpc::AsyncGenericService generic_service_;
    std::unique_ptr<grpc::ServerCompletionQueue> cq_;
    std::unique_ptr<grpc::Server> server_;
    std::mutex mu_;
    bool shutting_down_ = false;
    std::thread server_thread_;
    RecordingLoopbackServer* outer_;
  };

  static void ShutdownBounded(std::shared_ptr<Impl> impl) {
    struct Completion {
      std::mutex mu;
      std::condition_variable cv;
      bool done = false;
    };
    auto completion = std::make_shared<Completion>();
    int port = impl->port();
    std::thread([impl = std::move(impl), completion]() mutable {
      impl->Shutdown();
      impl.reset();
      {
        std::lock_guard<std::mutex> lock(completion->mu);
        completion->done = true;
      }
      completion->cv.notify_all();
    }).detach();
    std::unique_lock<std::mutex> lock(completion->mu);
    if (!completion->cv.wait_for(lock, kServerShutdownTimeout,
                                 [&] { return completion->done; })) {
      std::fprintf(stderr,
                   "WARNING: RecordingLoopbackServer on port %d did not shut "
                   "down within %d s; leaking it so the test process can "
                   "continue.\n",
                   port, static_cast<int>(kServerShutdownTimeout.count()));
    }
  }

  std::shared_ptr<Impl> impl_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::vector<RecordedCall> calls_;
};

class DemoAuthCredentialsProvider
    : public credentials::EmptyCredentialsProvider<AuthToken, User> {
 public:
  void GetToken(credentials::TokenListener<AuthToken> completion) override {
    if (completion) {
      completion(AuthToken(kDemoIDToken, User::FromUid("fake-uid")));
    }
  }
};

class DemoAppCheckCredentialsProvider
    : public credentials::EmptyCredentialsProvider<std::string, std::string> {
 public:
  void GetToken(
      credentials::TokenListener<std::string> completion) override {
    if (completion) {
      completion(std::string(kDemoAppCheckToken));
    }
  }
};

// Datastore with a public constructor for the test (same pattern as the
// FakeDatastore in datastore_test.cc).
class DemoDatastore : public Datastore {
 public:
  using Datastore::Datastore;
};

std::string MetadataValue(const RecordedCall& call, const std::string& key) {
  auto range = call.metadata.equal_range(key);
  if (range.first == range.second) return "<absent>";
  return range.first->second;
}

}  // namespace

class DemoTokenTest : public testing::Test {
 protected:
  std::shared_ptr<DemoDatastore> MakeDatastore(const std::string& host,
                                               bool ssl_enabled) {
    DatabaseInfo database_info{DatabaseId{"demo-project", "demo-db"}, "",
                               host, ssl_enabled};
    auto worker_queue = testutil::AsyncQueueForTesting();
    auto connectivity_monitor = CreateNoOpConnectivityMonitor();
    auto firebase_metadata_provider = CreateFirebaseMetadataProviderNoOp();
    auto auth = std::make_shared<DemoAuthCredentialsProvider>();
    auto app_check = std::make_shared<DemoAppCheckCredentialsProvider>();
    return std::make_shared<DemoDatastore>(
        database_info, worker_queue, auth, app_check,
        connectivity_monitor.get(), firebase_metadata_provider.get());
  }

  // Issues one Commit, waits for the server to record the call and then
  // for the client callback. Returns false with a message if either step
  // times out.
  bool RunCommitAndWait(std::shared_ptr<DemoDatastore> datastore,
                        RecordingLoopbackServer& server,
                        std::chrono::seconds timeout,
                        std::string* error) {
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;
    datastore->CommitMutations({}, [&](const Status& /*status*/) {
      {
        std::lock_guard<std::mutex> lock(mu);
        done = true;
      }
      cv.notify_all();
    });
    if (!server.WaitForCall(timeout)) {
      *error = "Server saw no call; the client never dialed the caller host.";
      return false;
    }
    std::unique_lock<std::mutex> lock(mu);
    if (!cv.wait_for(lock, timeout, [&] { return done; })) {
      *error = "Client callback never fired.";
      return false;
    }
    return true;
  }
};

// Leg 2: plaintext gRPC to a caller host carries the live ID token and the
// live App Check token as call metadata on the first request.
TEST_F(DemoTokenTest, PlaintextCommitSendsLiveTokens) {
  RecordingLoopbackServer server(grpc::InsecureServerCredentials());
  ASSERT_TRUE(server.started());

  auto datastore = MakeDatastore(server.target(), /*ssl_enabled=*/false);
  datastore->Start();

  std::string error;
  ASSERT_TRUE(RunCommitAndWait(datastore, server, std::chrono::seconds(15),
                               &error))
      << error;

  ASSERT_FALSE(server.calls().empty());
  const RecordedCall& call = server.calls().front();
  EXPECT_EQ(call.method, "/google.firestore.v1.Firestore/Commit");
  EXPECT_EQ(MetadataValue(call, "authorization"),
            std::string("Bearer ") + kDemoIDToken);
  EXPECT_EQ(MetadataValue(call, "x-firebase-appcheck"),
            std::string(kDemoAppCheckToken));

  datastore->Shutdown();
}

// Leg 1: TLS gRPC to a caller host carries the same two tokens. Needs a
// server certificate chaining to a system-trusted root; the workflow
// generates a throwaway test CA and installs it before this runs.
TEST_F(DemoTokenTest, TlsCommitSendsLiveTokens) {
  const char* cert_path = std::getenv("FIRESTORE_DEMO_TLS_CERT");
  const char* key_path = std::getenv("FIRESTORE_DEMO_TLS_KEY");
  if (cert_path == nullptr || key_path == nullptr) {
    GTEST_SKIP() << "FIRESTORE_DEMO_TLS_CERT / FIRESTORE_DEMO_TLS_KEY not "
                    "set; run scripts/make-firestore-test-ca.sh first.";
  }
  std::string cert = ReadFileOrEmpty(cert_path);
  std::string key = ReadFileOrEmpty(key_path);
  ASSERT_FALSE(cert.empty()) << "Cannot read " << cert_path;
  ASSERT_FALSE(key.empty()) << "Cannot read " << key_path;

  grpc::SslServerCredentialsOptions ssl_options;
  ssl_options.pem_key_cert_pairs.push_back({key, cert});
  RecordingLoopbackServer server(grpc::SslServerCredentials(ssl_options));
  ASSERT_TRUE(server.started());

  auto datastore = MakeDatastore(server.target(), /*ssl_enabled=*/true);
  datastore->Start();

  std::string error;
  ASSERT_TRUE(RunCommitAndWait(datastore, server, std::chrono::seconds(15),
                               &error))
      << error;

  ASSERT_FALSE(server.calls().empty());
  const RecordedCall& call = server.calls().front();
  EXPECT_EQ(call.method, "/google.firestore.v1.Firestore/Commit");
  EXPECT_EQ(MetadataValue(call, "authorization"),
            std::string("Bearer ") + kDemoIDToken);
  EXPECT_EQ(MetadataValue(call, "x-firebase-appcheck"),
            std::string(kDemoAppCheckToken));

  datastore->Shutdown();
}

}  // namespace remote
}  // namespace firestore
}  // namespace firebase
