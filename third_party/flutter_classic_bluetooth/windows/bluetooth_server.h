#ifndef FLUTTER_PLUGIN_BLUETOOTH_SERVER_H_
#define FLUTTER_PLUGIN_BLUETOOTH_SERVER_H_

#include <winsock2.h>
#include <ws2bth.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace flutter_classic_bluetooth {

class BluetoothServer {
 public:
  BluetoothServer(int id, const std::string& uuid, const std::string& service_name, bool secure);
  ~BluetoothServer();

  int id() const { return id_; }
  bool Start(std::function<void(SOCKET, const std::string&)> on_connection);
  void Stop();

 private:
  // Publishes (or removes) the RFCOMM service in the local SDP database so
  // remote devices can resolve uuid_ -> the bound RFCOMM channel.
  void SetSdpService(bool register_service);

  int id_;
  std::string uuid_;
  std::string service_name_;
  bool secure_;
  SOCKET server_socket_ = INVALID_SOCKET;
  SOCKADDR_BTH bound_addr_ = {};
  bool sdp_registered_ = false;
  std::atomic<bool> running_{false};
  std::thread accept_thread_;
};

}  // namespace flutter_classic_bluetooth

#endif  // FLUTTER_PLUGIN_BLUETOOTH_SERVER_H_
