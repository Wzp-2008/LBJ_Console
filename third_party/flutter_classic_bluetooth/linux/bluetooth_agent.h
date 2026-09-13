#ifndef BLUETOOTH_AGENT_H_
#define BLUETOOTH_AGENT_H_

#include <gio/gio.h>

// Auto-accepting BlueZ pairing agent (org.bluez.Agent1).
//
// Registering this as the default agent lets the plugin pair Secure Simple
// Pairing ("just works") devices (the vast majority of modern Bluetooth
// Classic modules, including ESP32 and most HC-05/06) directly from
// bondDevice(), with no desktop pairing dialog. Confirmation/authorization
// requests are auto-accepted; legacy devices that require the user to type a
// PIN or passkey are rejected (there is no interactive input path here). Pair
// those through a system agent.
//
// If the desktop already runs a default agent, RequestDefaultAgent quietly
// fails and that agent keeps handling pairing, so this is safe to register
// unconditionally.

static const char kBtcAgentPath[] = "/com/flutter_classic_bluetooth/agent";

static void btc_agent_method_call(GDBusConnection*, const gchar*, const gchar*,
                                  const gchar*, const gchar* method, GVariant*,
                                  GDBusMethodInvocation* invocation, gpointer) {
    if (g_strcmp0(method, "RequestConfirmation") == 0 ||
        g_strcmp0(method, "RequestAuthorization") == 0 ||
        g_strcmp0(method, "AuthorizeService") == 0 ||
        g_strcmp0(method, "DisplayPasskey") == 0 ||
        g_strcmp0(method, "DisplayPinCode") == 0 ||
        g_strcmp0(method, "Cancel") == 0 ||
        g_strcmp0(method, "Release") == 0) {
        // Accept (or acknowledge): this is what enables just-works pairing.
        g_dbus_method_invocation_return_value(invocation, nullptr);
    } else {
        // RequestPinCode / RequestPasskey and anything else: no input path.
        g_dbus_method_invocation_return_dbus_error(
            invocation, "org.bluez.Error.Rejected",
            "Interactive PIN/passkey entry is not supported");
    }
}

static const char kBtcAgentXml[] =
    "<node><interface name='org.bluez.Agent1'>"
    "<method name='Release'/>"
    "<method name='RequestPinCode'>"
    "<arg type='o' direction='in'/><arg type='s' direction='out'/></method>"
    "<method name='DisplayPinCode'>"
    "<arg type='o' direction='in'/><arg type='s' direction='in'/></method>"
    "<method name='RequestPasskey'>"
    "<arg type='o' direction='in'/><arg type='u' direction='out'/></method>"
    "<method name='DisplayPasskey'>"
    "<arg type='o' direction='in'/><arg type='u' direction='in'/>"
    "<arg type='q' direction='in'/></method>"
    "<method name='RequestConfirmation'>"
    "<arg type='o' direction='in'/><arg type='u' direction='in'/></method>"
    "<method name='RequestAuthorization'>"
    "<arg type='o' direction='in'/></method>"
    "<method name='AuthorizeService'>"
    "<arg type='o' direction='in'/><arg type='s' direction='in'/></method>"
    "<method name='Cancel'/>"
    "</interface></node>";

// Registers the Agent1 object and asks BlueZ to make it the default agent.
// Returns the object-registration id (0 on failure) and, via [out_node], the
// node info the caller must keep and unref at teardown.
inline guint dbus_register_pairing_agent(GDBusConnection* bus,
                                         GDBusNodeInfo** out_node) {
    *out_node = nullptr;
    if (!bus) return 0;

    GError* error = nullptr;
    GDBusNodeInfo* node = g_dbus_node_info_new_for_xml(kBtcAgentXml, &error);
    if (!node) {
        if (error) g_error_free(error);
        return 0;
    }

    static const GDBusInterfaceVTable vtable = {btc_agent_method_call, nullptr,
                                                nullptr};
    guint reg_id = g_dbus_connection_register_object(
        bus, kBtcAgentPath, node->interfaces[0], &vtable, nullptr, nullptr,
        &error);
    if (reg_id == 0) {
        if (error) g_error_free(error);
        g_dbus_node_info_unref(node);
        return 0;
    }

    GVariant* r1 = g_dbus_connection_call_sync(
        bus, "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
        "RegisterAgent",
        g_variant_new("(os)", kBtcAgentPath, "NoInputNoOutput"), nullptr,
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (r1) g_variant_unref(r1);
    if (error) {
        // Already registered or BlueZ unavailable: keep the object but report
        // no registration so pairing falls back to any system agent.
        g_error_free(error);
        error = nullptr;
    }

    GVariant* r2 = g_dbus_connection_call_sync(
        bus, "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
        "RequestDefaultAgent", g_variant_new("(o)", kBtcAgentPath), nullptr,
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    if (r2) g_variant_unref(r2);
    if (error) g_error_free(error);  // another default exists, non-fatal

    *out_node = node;
    return reg_id;
}

// Unregisters the agent and releases its object. Safe with a 0 id / null node.
inline void dbus_unregister_pairing_agent(GDBusConnection* bus, guint reg_id,
                                          GDBusNodeInfo* node) {
    if (bus && reg_id != 0) {
        GError* error = nullptr;
        GVariant* r = g_dbus_connection_call_sync(
            bus, "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
            "UnregisterAgent", g_variant_new("(o)", kBtcAgentPath), nullptr,
            G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
        if (r) g_variant_unref(r);
        if (error) g_error_free(error);
        g_dbus_connection_unregister_object(bus, reg_id);
    }
    if (node) g_dbus_node_info_unref(node);
}

#endif  // BLUETOOTH_AGENT_H_
