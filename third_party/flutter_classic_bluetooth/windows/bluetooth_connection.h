#ifndef FLUTTER_PLUGIN_BLUETOOTH_CONNECTION_H_
#define FLUTTER_PLUGIN_BLUETOOTH_CONNECTION_H_

#include <winsock2.h>
#include <ws2bth.h>

#include <flutter/event_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace flutter_classic_bluetooth {

class BluetoothConnection {
 public:
  BluetoothConnection(int id, SOCKET socket, const std::string& address);
  ~BluetoothConnection();

  int id() const { return id_; }
  const std::string& address() const { return address_; }
  bool is_connected() const { return connected_.load(); }

  void StartReading(
      std::function<void(const std::vector<uint8_t>&)> on_data,
      std::function<void()> on_disconnected);
  bool Write(const std::vector<uint8_t>& data);
  void Close();

 private:
  int id_;
  SOCKET socket_;
  std::string address_;
  std::atomic<bool> connected_{true};
  std::thread read_thread_;
};

}  // namespace flutter_classic_bluetooth

#endif  // FLUTTER_PLUGIN_BLUETOOTH_CONNECTION_H_
