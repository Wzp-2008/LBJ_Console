#ifndef FLUTTER_PLUGIN_FLUTTER_CLASSIC_BLUETOOTH_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_CLASSIC_BLUETOOTH_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "bluetooth_connection.h"
#include "bluetooth_server.h"

// <windows.h> must come after <winsock2.h> (pulled in by bluetooth_connection.h).
#include <windows.h>

#include <atomic>
#include <functional>
#include <queue>
#include <thread>

namespace flutter_classic_bluetooth {

// StreamHandler that stores the event sink for later use
class PluginStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
    sink_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override {
    sink_.reset();
    return nullptr;
  }

  flutter::EventSink<flutter::EncodableValue>* sink() const { return sink_.get(); }

 private:
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

// Marshals arbitrary callbacks onto the platform (UI) thread.
//
// Flutter requires every EventSink/MethodResult call to happen on the platform
// thread. Bluetooth I/O runs on background threads, so producers post their
// sink calls here and a message-only window drains them on the platform thread.
// Created and destroyed on the platform thread.
class UiThreadDispatcher {
 public:
  UiThreadDispatcher() {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.lpszClassName = L"FlutterClassicBluetoothDispatcher";
    RegisterClassExW(&wc);
    hwnd_ = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, wc.hInstance, this);
  }

  ~UiThreadDispatcher() {
    if (hwnd_) DestroyWindow(hwnd_);
  }

  UiThreadDispatcher(const UiThreadDispatcher&) = delete;
  UiThreadDispatcher& operator=(const UiThreadDispatcher&) = delete;

  // Thread-safe. The task runs later on the platform thread.
  void Post(std::function<void()> task) {
    if (!hwnd_) return;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      queue_.push(std::move(task));
    }
    PostMessageW(hwnd_, kRunTask, 0, 0);
  }

 private:
  static constexpr UINT kRunTask = WM_USER + 0x42;

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == WM_NCCREATE) {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    } else if (msg == kRunTask) {
      auto* self = reinterpret_cast<UiThreadDispatcher*>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      if (self) self->Drain();
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  void Drain() {
    std::queue<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::swap(tasks, queue_);
    }
    while (!tasks.empty()) {
      tasks.front()();
      tasks.pop();
    }
  }

  HWND hwnd_ = nullptr;
  std::mutex mutex_;
  std::queue<std::function<void()>> queue_;
};

// Thread-safe owner of an event sink, shared between the StreamHandler (owned
// by the EventChannel) and the producer threads via shared_ptr. Outliving any
// in-flight dispatcher task it is captured by guarantees there is no
// use-after-free when a connection closes. Success/EndOfStream must be invoked
// on the platform thread (route them through UiThreadDispatcher).
class SinkHolder {
 public:
  void SetSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_ = std::move(sink);
  }

  void ClearSink() {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_.reset();
  }

  void Success(const flutter::EncodableValue& value) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_) sink_->Success(value);
  }

  void EndOfStream() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sink_) sink_->EndOfStream();
  }

 private:
  std::mutex mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

// StreamHandler that forwards listen/cancel to a shared SinkHolder.
class SharedStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit SharedStreamHandler(std::shared_ptr<SinkHolder> holder)
      : holder_(std::move(holder)) {}

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
    holder_->SetSink(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override {
    holder_->ClearSink();
    return nullptr;
  }

 private:
  std::shared_ptr<SinkHolder> holder_;
};

// Per-connection event channels (data + state) and their sink holders.
struct ConnectionChannels {
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> data_channel;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> state_channel;
  std::shared_ptr<SinkHolder> data_sink = std::make_shared<SinkHolder>();
  std::shared_ptr<SinkHolder> state_sink = std::make_shared<SinkHolder>();
};

// Per-server event channel (server/{id}) delivering accepted client connections
// to Dart's BtcServerSocket.connections stream.
struct ServerChannel {
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> channel;
  std::shared_ptr<SinkHolder> sink = std::make_shared<SinkHolder>();
};

class FlutterClassicBluetoothPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterClassicBluetoothPlugin(flutter::BinaryMessenger* messenger);
  virtual ~FlutterClassicBluetoothPlugin();

  FlutterClassicBluetoothPlugin(const FlutterClassicBluetoothPlugin&) = delete;
  FlutterClassicBluetoothPlugin& operator=(const FlutterClassicBluetoothPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  flutter::BinaryMessenger* messenger_;
  bool wsa_initialized_ = false;

  std::map<int, std::unique_ptr<BluetoothConnection>> connections_;
  std::map<int, std::unique_ptr<BluetoothServer>> servers_;
  // Per-connection event channels, keyed by connection id. Guarded by
  // connections_mutex_ together with connections_.
  std::map<int, std::shared_ptr<ConnectionChannels>> connection_channels_;
  // Per-server event channels, keyed by server id. Guarded by servers_mutex_.
  std::map<int, std::shared_ptr<ServerChannel>> server_channels_;
  std::mutex connections_mutex_;
  std::mutex servers_mutex_;
  int next_connection_id_ = 1;
  int next_server_id_ = 1;

  // Drains background-thread sink callbacks onto the platform thread.
  std::shared_ptr<UiThreadDispatcher> dispatcher_;

  // Discovery
  std::atomic<bool> discovering_{false};
  std::thread discovery_thread_;

  // Event channels
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> adapter_state_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> discovery_state_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> discovery_results_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> bond_state_channel_;
  PluginStreamHandler* adapter_state_handler_ = nullptr;
  PluginStreamHandler* discovery_state_handler_ = nullptr;
  PluginStreamHandler* discovery_results_handler_ = nullptr;

  void InitWinsock();
  void CleanupWinsock();

  // Method handlers
  void HandleIsSupported(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleIsEnabled(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetAdapterName(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetAdapterAddress(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleStartDiscovery(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleStopDiscovery(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetPairedDevices(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleBondDevice(const flutter::EncodableMap& args,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleUnbondDevice(const flutter::EncodableMap& args,
                          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleConnect(const flutter::EncodableMap& args,
                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleDisconnect(const flutter::EncodableMap& args,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleWrite(const flutter::EncodableMap& args,
                   std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleStartServer(const flutter::EncodableMap& args,
                         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleStopServer(const flutter::EncodableMap& args,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleSetDiscoverable(
      const flutter::EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetPlatformCapabilities(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Registers the connection/{id} and connection_state/{id} event channels for
  // a newly established connection and starts its read loop. Must be called on
  // the platform thread while holding connections_mutex_.
  void SetupConnectionStreams(int conn_id, BluetoothConnection* connection);
};

}  // namespace flutter_classic_bluetooth

#endif  // FLUTTER_PLUGIN_FLUTTER_CLASSIC_BLUETOOTH_PLUGIN_H_
