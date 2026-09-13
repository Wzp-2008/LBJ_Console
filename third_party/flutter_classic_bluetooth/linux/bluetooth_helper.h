#ifndef BLUETOOTH_HELPER_H_
#define BLUETOOTH_HELPER_H_

#include <flutter_linux/flutter_linux.h>
#include <string>
#include <cstdio>
#include <climits>
#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>
#include <bluetooth/hci_lib.h>
#include <bluetooth/rfcomm.h>
#include <bluetooth/sdp.h>
#include <bluetooth/sdp_lib.h>

// Builds the device map sent to Dart. Keys match BtcDevice.fromMap on every
// platform: address, name, alias, type, bondState, rssi, uuids. Pass
// rssi == INT_MIN to report a null (unknown) signal strength.
inline FlValue* device_to_map(const char* address, const char* name,
                               bool paired, int rssi = INT_MIN) {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "address", fl_value_new_string(address));
    fl_value_set_string_take(map, "name", name ? fl_value_new_string(name) : fl_value_new_null());
    fl_value_set_string_take(map, "alias", fl_value_new_null());
    fl_value_set_string_take(map, "type", fl_value_new_string("classic"));
    fl_value_set_string_take(map, "bondState",
        fl_value_new_string(paired ? "bonded" : "none"));
    fl_value_set_string_take(map, "rssi",
        rssi == INT_MIN ? fl_value_new_null() : fl_value_new_int(rssi));
    fl_value_set_string_take(map, "uuids", fl_value_new_list());
    return map;
}

// Resolves the RFCOMM server channel a remote device advertises for the given
// service UUID via an SDP query. Returns the channel number, or -1 if it could
// not be resolved (caller should fall back to a default channel).
inline int sdp_find_rfcomm_channel(const bdaddr_t* target, const char* uuid_str) {
    unsigned int b[16];
    if (sscanf(uuid_str, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7],
               &b[8], &b[9], &b[10], &b[11], &b[12], &b[13], &b[14], &b[15]) != 16) {
        return -1;
    }
    uint8_t uuid_int[16];
    for (int i = 0; i < 16; i++) uuid_int[i] = (uint8_t)b[i];

    uuid_t svc_uuid;
    sdp_uuid128_create(&svc_uuid, uuid_int);

    bdaddr_t any = {{0, 0, 0, 0, 0, 0}};
    sdp_session_t* session = sdp_connect(&any, target, SDP_RETRY_IF_BUSY);
    if (!session) return -1;

    sdp_list_t* search = sdp_list_append(nullptr, &svc_uuid);
    uint32_t range = 0x0000ffff;
    sdp_list_t* attrid = sdp_list_append(nullptr, &range);
    sdp_list_t* response = nullptr;

    int channel = -1;
    if (sdp_service_search_attr_req(session, search, SDP_ATTR_REQ_RANGE,
                                    attrid, &response) == 0) {
        for (sdp_list_t* r = response; r; r = r->next) {
            sdp_record_t* rec = (sdp_record_t*)r->data;
            sdp_list_t* proto_list = nullptr;
            if (sdp_get_access_protos(rec, &proto_list) == 0 && proto_list) {
                int ch = sdp_get_proto_port(proto_list, RFCOMM_UUID);
                if (ch > 0) channel = ch;
                sdp_list_free(proto_list, (sdp_free_func_t)sdp_data_free);
            }
            sdp_record_free(rec);
            if (channel > 0) break;
        }
    }

    sdp_list_free(search, nullptr);
    sdp_list_free(attrid, nullptr);
    sdp_close(session);
    return channel;
}

inline sdp_session_t* register_rfcomm_service(uint8_t channel, const char* service_name,
                                                const char* uuid_str) {
    uint8_t svc_uuid_int[16];
    // Parse UUID string to bytes
    unsigned int b[16];
    if (sscanf(uuid_str, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7],
               &b[8], &b[9], &b[10], &b[11], &b[12], &b[13], &b[14], &b[15]) != 16) {
        return nullptr;
    }
    for (int i = 0; i < 16; i++) svc_uuid_int[i] = (uint8_t)b[i];

    uuid_t root_uuid, l2cap_uuid, rfcomm_uuid, svc_uuid;
    sdp_list_t *l2cap_list = nullptr, *rfcomm_list = nullptr,
               *root_list = nullptr, *proto_list = nullptr,
               *access_proto_list = nullptr, *svc_class_list = nullptr;
    sdp_data_t *channel_data = nullptr;
    sdp_record_t *record = sdp_record_alloc();

    sdp_uuid128_create(&svc_uuid, svc_uuid_int);
    svc_class_list = sdp_list_append(nullptr, &svc_uuid);
    sdp_set_service_classes(record, svc_class_list);

    sdp_uuid16_create(&root_uuid, PUBLIC_BROWSE_GROUP);
    root_list = sdp_list_append(nullptr, &root_uuid);
    sdp_set_browse_groups(record, root_list);

    sdp_uuid16_create(&l2cap_uuid, L2CAP_UUID);
    l2cap_list = sdp_list_append(nullptr, &l2cap_uuid);
    proto_list = sdp_list_append(nullptr, l2cap_list);

    sdp_uuid16_create(&rfcomm_uuid, RFCOMM_UUID);
    channel_data = sdp_data_alloc(SDP_UINT8, &channel);
    rfcomm_list = sdp_list_append(nullptr, &rfcomm_uuid);
    sdp_list_append(rfcomm_list, channel_data);
    sdp_list_append(proto_list, rfcomm_list);

    access_proto_list = sdp_list_append(nullptr, proto_list);
    sdp_set_access_protos(record, access_proto_list);

    sdp_set_info_attr(record, service_name, "", "");

    bdaddr_t any = {{0, 0, 0, 0, 0, 0}};          // BDADDR_ANY
    bdaddr_t local = {{0, 0, 0, 0xff, 0xff, 0xff}};  // BDADDR_LOCAL (local SDP daemon)
    sdp_session_t* session = sdp_connect(&any, &local, SDP_RETRY_IF_BUSY);
    if (session) {
        sdp_record_register(session, record, 0);
    }

    sdp_data_free(channel_data);
    sdp_list_free(l2cap_list, nullptr);
    sdp_list_free(rfcomm_list, nullptr);
    sdp_list_free(root_list, nullptr);
    sdp_list_free(access_proto_list, nullptr);
    sdp_list_free(svc_class_list, nullptr);
    sdp_record_free(record);

    return session;
}

#endif  // BLUETOOTH_HELPER_H_
