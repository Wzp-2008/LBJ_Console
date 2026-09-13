#ifndef BLUETOOTH_DBUS_H_
#define BLUETOOTH_DBUS_H_

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <climits>
#include <cstring>
#include <functional>
#include <string>

#include "bluetooth_helper.h"

// BlueZ D-Bus (org.bluez) access layer.
//
// This is the primary interface for everything that does not require a raw
// RFCOMM socket: adapter presence/power/name/address, device discovery,
// discoverability, paired-device enumeration and pairing/unpairing. Talking to
// BlueZ over the system bus works for an ordinary desktop user (mediated by
// polkit), whereas the raw HCI socket interface needs CAP_NET_RAW/root, so
// D-Bus is what lets the plugin function in a normal Flutter desktop app.
//
// Every helper takes the caller-owned system-bus connection. When the bus is
// null (no system bus / BlueZ not running) helpers return false / no-op so the
// caller can fall back to the raw-HCI code paths.

// ── Object-path helpers ────────────────────────────────────────────────────

// Builds a device object path under an adapter path, e.g.
// "/org/bluez/hci0" + "AA:BB:.." -> "/org/bluez/hci0/dev_AA_BB_..".
inline std::string dbus_device_path_under(const std::string& adapter_path,
                                          const char* address) {
    std::string path = adapter_path + "/dev_";
    for (const char* p = address; *p; ++p) {
        char c = *p;
        if (c == ':') c = '_';
        else if (c >= 'a' && c <= 'f') c = static_cast<char>(c - 'a' + 'A');
        path += c;
    }
    return path;
}

// Extracts an uppercase "AA:BB:.." address from a device object path, or "".
inline std::string dbus_address_from_path(const char* path) {
    const char* d = path ? strstr(path, "/dev_") : nullptr;
    if (!d) return "";
    d += 5;  // skip "/dev_"
    std::string a;
    for (const char* p = d; *p && *p != '/'; ++p) {
        char c = *p;
        if (c == '_') c = ':';
        else if (c >= 'a' && c <= 'f') c = static_cast<char>(c - 'a' + 'A');
        a += c;
    }
    return a;
}

// ── Adapter discovery & properties ─────────────────────────────────────────

// Returns the object path of the first org.bluez.Adapter1, or "" if none.
inline std::string dbus_find_adapter_path(GDBusConnection* bus) {
    if (!bus) return "";
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", "/",
        "org.freedesktop.DBus.ObjectManager", "GetManagedObjects",
        nullptr, G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (!ret) { if (error) g_error_free(error); return ""; }

    std::string found;
    GVariantIter* objects = nullptr;
    g_variant_get(ret, "(a{oa{sa{sv}}})", &objects);
    const gchar* obj_path = nullptr;
    GVariantIter* interfaces = nullptr;
    while (g_variant_iter_loop(objects, "{&oa{sa{sv}}}", &obj_path, &interfaces)) {
        const gchar* iface = nullptr;
        GVariant* props = nullptr;
        while (g_variant_iter_loop(interfaces, "{&s@a{sv}}", &iface, &props)) {
            if (found.empty() && g_strcmp0(iface, "org.bluez.Adapter1") == 0) {
                found = obj_path;
            }
        }
    }
    g_variant_iter_free(objects);
    g_variant_unref(ret);
    return found;
}

// Returns true if a BlueZ adapter is present on the system.
inline bool dbus_adapter_present(GDBusConnection* bus) {
    return !dbus_find_adapter_path(bus).empty();
}

// Reads one Adapter1 property as an owned GVariant (caller unrefs), or null.
inline GVariant* dbus_adapter_get(GDBusConnection* bus, const char* prop) {
    std::string path = dbus_find_adapter_path(bus);
    if (path.empty()) return nullptr;
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(),
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.bluez.Adapter1", prop),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (!ret) { if (error) g_error_free(error); return nullptr; }
    GVariant* val = nullptr;
    g_variant_get(ret, "(v)", &val);
    g_variant_unref(ret);
    return val;  // may be null
}

// Reads the adapter Powered flag. Returns true if BlueZ answered.
inline bool dbus_try_powered(GDBusConnection* bus, bool* out) {
    GVariant* v = dbus_adapter_get(bus, "Powered");
    if (!v) return false;
    *out = g_variant_get_boolean(v);
    g_variant_unref(v);
    return true;
}

// Reads a string adapter property (e.g. "Alias", "Address"). Returns true if
// BlueZ answered.
inline bool dbus_try_adapter_string(GDBusConnection* bus, const char* prop,
                                    std::string* out) {
    GVariant* v = dbus_adapter_get(bus, prop);
    if (!v) return false;
    const char* s = g_variant_get_string(v, nullptr);
    *out = s ? s : "";
    g_variant_unref(v);
    return true;
}

// Sets the adapter's Powered property (enable/disable Bluetooth).
inline bool dbus_set_adapter_powered(GDBusConnection* bus, bool powered) {
    std::string path = dbus_find_adapter_path(bus);
    if (path.empty()) return false;
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(),
        "org.freedesktop.DBus.Properties", "Set",
        g_variant_new("(ssv)", "org.bluez.Adapter1", "Powered",
                      g_variant_new_boolean(powered)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    bool ok = ret != nullptr;
    if (ret) g_variant_unref(ret);
    if (error) g_error_free(error);
    return ok;
}

// ── Discovery ──────────────────────────────────────────────────────────────

// Starts BlueZ device discovery, filtered to Bluetooth Classic (BR/EDR).
inline bool dbus_start_discovery(GDBusConnection* bus) {
    std::string path = dbus_find_adapter_path(bus);
    if (path.empty()) return false;

    // Restrict results to BR/EDR (Bluetooth Classic). Best-effort: an older
    // BlueZ that rejects the filter still discovers, just unfiltered.
    GError* error = nullptr;
    GVariantBuilder filter;
    g_variant_builder_init(&filter, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&filter, "{sv}", "Transport",
                          g_variant_new_string("bredr"));
    GVariant* fret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(), "org.bluez.Adapter1",
        "SetDiscoveryFilter", g_variant_new("(a{sv})", &filter),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (fret) g_variant_unref(fret);
    if (error) { g_error_free(error); error = nullptr; }

    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(), "org.bluez.Adapter1",
        "StartDiscovery", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    bool ok = ret != nullptr;
    if (ret) g_variant_unref(ret);
    if (error) g_error_free(error);  // e.g. already in progress
    return ok;
}

// Stops BlueZ device discovery.
inline bool dbus_stop_discovery(GDBusConnection* bus) {
    std::string path = dbus_find_adapter_path(bus);
    if (path.empty()) return false;
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(), "org.bluez.Adapter1",
        "StopDiscovery", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    bool ok = ret != nullptr;
    if (ret) g_variant_unref(ret);
    if (error) g_error_free(error);
    return ok;
}

// Sets the adapter Discoverable flag and its timeout. BlueZ reverts to
// non-discoverable automatically after `timeout` seconds (0 = no timeout).
inline bool dbus_set_discoverable(GDBusConnection* bus, bool on, int timeout) {
    std::string path = dbus_find_adapter_path(bus);
    if (path.empty()) return false;
    GError* error = nullptr;
    GVariant* r1 = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(),
        "org.freedesktop.DBus.Properties", "Set",
        g_variant_new("(ssv)", "org.bluez.Adapter1", "DiscoverableTimeout",
                      g_variant_new_uint32(on && timeout > 0
                                               ? static_cast<guint32>(timeout)
                                               : 0)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (r1) g_variant_unref(r1);
    if (error) { g_error_free(error); error = nullptr; }

    GVariant* r2 = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(),
        "org.freedesktop.DBus.Properties", "Set",
        g_variant_new("(ssv)", "org.bluez.Adapter1", "Discoverable",
                      g_variant_new_boolean(on)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    bool ok = r2 != nullptr;
    if (r2) g_variant_unref(r2);
    if (error) g_error_free(error);
    return ok;
}

// ── Devices ────────────────────────────────────────────────────────────────

// Calls org.bluez.Device1.Pair. Succeeds for "just works"/SSP devices; devices
// requiring a PIN/passkey need a registered agent and may fail.
inline bool dbus_pair_device(GDBusConnection* bus, const char* address) {
    std::string adapter = dbus_find_adapter_path(bus);
    if (adapter.empty()) return false;
    std::string path = dbus_device_path_under(adapter, address);
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(),
        "org.bluez.Device1", "Pair", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, 30000, nullptr, &error);
    bool ok = ret != nullptr;
    if (ret) g_variant_unref(ret);
    if (error) g_error_free(error);
    return ok;
}

// Calls org.bluez.Adapter1.RemoveDevice (unpair).
inline bool dbus_remove_device(GDBusConnection* bus, const char* address) {
    std::string adapter = dbus_find_adapter_path(bus);
    if (adapter.empty()) return false;
    std::string dev = dbus_device_path_under(adapter, address);
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", adapter.c_str(),
        "org.bluez.Adapter1", "RemoveDevice",
        g_variant_new("(o)", dev.c_str()),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    bool ok = ret != nullptr;
    if (ret) g_variant_unref(ret);
    if (error) g_error_free(error);
    return ok;
}

// Reads a device's Paired flag. Returns true if BlueZ answered.
inline bool dbus_try_device_paired(GDBusConnection* bus, const char* address,
                                   bool* out) {
    std::string adapter = dbus_find_adapter_path(bus);
    if (adapter.empty()) return false;
    std::string path = dbus_device_path_under(adapter, address);
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", path.c_str(),
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.bluez.Device1", "Paired"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (!ret) { if (error) g_error_free(error); return false; }
    GVariant* v = nullptr;
    g_variant_get(ret, "(v)", &v);
    *out = v ? g_variant_get_boolean(v) : false;
    if (v) g_variant_unref(v);
    g_variant_unref(ret);
    return true;
}

// Builds the Dart device map from a BlueZ Device1 property dict (a{sv}).
// `fallback_address` is used when the dict has no "Address" (e.g. a
// PropertiesChanged delta); returns null if no address can be determined.
inline FlValue* dbus_device_map_from_props(GVariant* props,
                                           const std::string& fallback_address) {
    std::string address = fallback_address;
    std::string name;
    bool paired = false;
    int rssi = INT_MIN;

    GVariantIter it;
    g_variant_iter_init(&it, props);
    const gchar* key = nullptr;
    GVariant* value = nullptr;
    while (g_variant_iter_loop(&it, "{&sv}", &key, &value)) {
        if (g_strcmp0(key, "Address") == 0) {
            address = g_variant_get_string(value, nullptr);
        } else if (g_strcmp0(key, "Name") == 0) {
            name = g_variant_get_string(value, nullptr);
        } else if (g_strcmp0(key, "Alias") == 0 && name.empty()) {
            name = g_variant_get_string(value, nullptr);
        } else if (g_strcmp0(key, "Paired") == 0) {
            paired = g_variant_get_boolean(value);
        } else if (g_strcmp0(key, "RSSI") == 0) {
            rssi = g_variant_get_int16(value);
        }
    }
    if (address.empty()) return nullptr;
    for (auto& c : address) {
        if (c >= 'a' && c <= 'f') c = static_cast<char>(c - 'a' + 'A');
    }
    return device_to_map(address.c_str(), name.empty() ? nullptr : name.c_str(),
                         paired, rssi);
}

// Invokes `fn(object_path, device_props)` for every org.bluez.Device1 BlueZ
// currently knows about (the standard ObjectManager.GetManagedObjects pattern).
inline void dbus_for_each_device(
    GDBusConnection* bus,
    const std::function<void(const char* path, GVariant* props)>& fn) {
    if (!bus) return;
    GError* error = nullptr;
    GVariant* ret = g_dbus_connection_call_sync(
        bus, "org.bluez", "/",
        "org.freedesktop.DBus.ObjectManager", "GetManagedObjects",
        nullptr, G_VARIANT_TYPE("(a{oa{sa{sv}}})"),
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (!ret) { if (error) g_error_free(error); return; }

    GVariantIter* objects = nullptr;
    g_variant_get(ret, "(a{oa{sa{sv}}})", &objects);
    const gchar* obj_path = nullptr;
    GVariantIter* interfaces = nullptr;
    while (g_variant_iter_loop(objects, "{&oa{sa{sv}}}", &obj_path, &interfaces)) {
        const gchar* iface = nullptr;
        GVariant* props = nullptr;
        while (g_variant_iter_loop(interfaces, "{&s@a{sv}}", &iface, &props)) {
            if (g_strcmp0(iface, "org.bluez.Device1") == 0) {
                fn(obj_path, props);
            }
        }
    }
    g_variant_iter_free(objects);
    g_variant_unref(ret);
}

// Appends every paired org.bluez.Device1 to `devices` (an FlValue list).
inline void dbus_append_paired_devices(GDBusConnection* bus, FlValue* devices) {
    dbus_for_each_device(bus, [devices](const char*, GVariant* props) {
        // Only include devices that are actually paired.
        GVariant* paired_v = g_variant_lookup_value(props, "Paired",
                                                    G_VARIANT_TYPE_BOOLEAN);
        bool paired = paired_v && g_variant_get_boolean(paired_v);
        if (paired_v) g_variant_unref(paired_v);
        if (!paired) return;
        FlValue* map = dbus_device_map_from_props(props, "");
        if (map) fl_value_append_take(devices, map);
    });
}

#endif  // BLUETOOTH_DBUS_H_
