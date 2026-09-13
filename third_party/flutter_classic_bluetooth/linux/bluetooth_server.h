#ifndef BLUETOOTH_SERVER_H_
#define BLUETOOTH_SERVER_H_

#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <functional>
#include <unistd.h>
#include <sys/socket.h>
#include <bluetooth/bluetooth.h>
#include <bluetooth/rfcomm.h>
#include <bluetooth/sdp.h>
#include <bluetooth/sdp_lib.h>

#include "bluetooth_helper.h"

class BluetoothServer {
public:
    BluetoothServer(int id, const std::string& uuid, const std::string& service_name,
                    bool secure = true)
        : id_(id), uuid_(uuid), service_name_(service_name), secure_(secure),
          socket_(-1), running_(false), sdp_session_(nullptr) {}

    ~BluetoothServer() { Stop(); }

    int id() const { return id_; }

    bool Start(uint8_t channel, std::function<void(int, const std::string&)> on_connection) {
        socket_ = socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM);
        if (socket_ < 0) return false;

        // Honor the secure flag: require authentication + encryption on accepted
        // links. Best-effort, ignored if the kernel rejects the option.
        if (secure_) {
            int lm = RFCOMM_LM_AUTH | RFCOMM_LM_ENCRYPT;
            setsockopt(socket_, SOL_RFCOMM, RFCOMM_LM, &lm, sizeof(lm));
        }

        struct sockaddr_rc addr = {};
        addr.rc_family = AF_BLUETOOTH;
        addr.rc_bdaddr = {{0, 0, 0, 0, 0, 0}};
        addr.rc_channel = channel;

        if (bind(socket_, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            close(socket_);
            socket_ = -1;
            return false;
        }

        if (listen(socket_, 1) < 0) {
            close(socket_);
            socket_ = -1;
            return false;
        }

        // Register SDP service
        sdp_session_ = register_rfcomm_service(channel, service_name_.c_str(), uuid_.c_str());

        running_.store(true);
        std::thread([this, on_connection]() {
            while (running_.load()) {
                struct sockaddr_rc client_addr = {};
                socklen_t addr_len = sizeof(client_addr);
                int client_socket = accept(socket_, (struct sockaddr*)&client_addr, &addr_len);
                if (client_socket < 0) break;

                char addr_str[19] = {};
                ba2str(&client_addr.rc_bdaddr, addr_str);
                if (on_connection) {
                    on_connection(client_socket, std::string(addr_str));
                }
            }
        }).detach();

        return true;
    }

    void Stop() {
        running_.store(false);
        if (socket_ >= 0) {
            shutdown(socket_, SHUT_RDWR);
            close(socket_);
            socket_ = -1;
        }
        if (sdp_session_) {
            sdp_close(sdp_session_);
            sdp_session_ = nullptr;
        }
    }

private:
    int id_;
    std::string uuid_;
    std::string service_name_;
    bool secure_;
    int socket_;
    std::atomic<bool> running_;
    sdp_session_t* sdp_session_;
};

#endif  // BLUETOOTH_SERVER_H_
