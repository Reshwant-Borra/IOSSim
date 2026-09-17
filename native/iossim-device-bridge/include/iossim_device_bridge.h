#ifndef IOSSIM_DEVICE_BRIDGE_H
#define IOSSIM_DEVICE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
#define IOSSIM_DEVICE_BRIDGE_ABI_VERSION 2u

typedef enum iossim_bridge_connection_kind {
    IOSSIM_BRIDGE_CONNECTION_UNKNOWN = 0,
    IOSSIM_BRIDGE_CONNECTION_USB = 1,
    IOSSIM_BRIDGE_CONNECTION_WIRELESS = 2
} iossim_bridge_connection_kind;

typedef enum iossim_bridge_status {
    IOSSIM_BRIDGE_OK = 0,
    IOSSIM_BRIDGE_INVALID_ARGUMENT = 1,
    IOSSIM_BRIDGE_UNAVAILABLE = 2,
    IOSSIM_BRIDGE_DEVICE_NOT_FOUND = 3,
    IOSSIM_BRIDGE_DEVICE_DISCONNECTED = 4,
    IOSSIM_BRIDGE_DEVICE_LOCKED = 5,
    IOSSIM_BRIDGE_TRUST_REQUIRED = 6,
    IOSSIM_BRIDGE_DEVELOPER_MODE_REQUIRED = 7,
    IOSSIM_BRIDGE_CANCELLED = 8,
    IOSSIM_BRIDGE_TIMED_OUT = 9,
    IOSSIM_BRIDGE_PROTOCOL_ERROR = 10,
    IOSSIM_BRIDGE_INTERNAL_ERROR = 11,
    IOSSIM_BRIDGE_DEVICE_RESOLUTION_FAILED = 12,
    IOSSIM_BRIDGE_COREDEVICE_PROXY_FAILED = 13,
    IOSSIM_BRIDGE_SOFTWARE_TUNNEL_FAILED = 14,
    IOSSIM_BRIDGE_RSD_UNAVAILABLE = 15,
    IOSSIM_BRIDGE_REMOTEXPC_FAILED = 16,
    IOSSIM_BRIDGE_APPSERVICE_UNAVAILABLE = 17,
    IOSSIM_BRIDGE_FEATURE_UNAVAILABLE = 18,
    IOSSIM_BRIDGE_APPLICATION_NOT_FOUND = 19,
    IOSSIM_BRIDGE_DDI_REQUIRED = 20,
    IOSSIM_BRIDGE_DEVELOPER_SERVICES_NOT_READY = 21,
    IOSSIM_BRIDGE_LAUNCH_REJECTED = 22,
    IOSSIM_BRIDGE_CONTAINER_UNAVAILABLE = 23,
    IOSSIM_BRIDGE_PAIRING_REJECTED = 24,
    IOSSIM_BRIDGE_PAIRING_PENDING = 25,
    IOSSIM_BRIDGE_PAIRING_DENIED = 26
} iossim_bridge_status;

typedef struct iossim_bridge_result {
    int32_t status;
    uint8_t *payload;
    size_t payload_len;
    char *diagnostic;
} iossim_bridge_result;

typedef struct iossim_device_handle iossim_device_handle;

uint32_t iossim_bridge_abi_version(void);
const char *iossim_bridge_version(void);

/* Results are owned by the caller and must be released with result_free. */
iossim_bridge_result *iossim_bridge_list_devices(uint64_t timeout_ms);
iossim_bridge_result *iossim_bridge_open_device(
    const uint8_t *stable_id,
    size_t stable_id_len,
    uint32_t expected_usbmux_id,
    uint32_t expected_connection,
    uint64_t connection_generation,
    uint64_t timeout_ms,
    iossim_device_handle **out_handle
);
iossim_bridge_result *iossim_bridge_inspect_device(
    iossim_device_handle *handle,
    uint64_t timeout_ms
);
/* Invokes Lockdown Pair exactly once. It never auto-approves Apple's Trust UI.
 * A successful payload is a secret-free persistence/session-validation receipt;
 * raw pairing records never cross this ABI. */
iossim_bridge_result *iossim_bridge_pair_lockdown_once(
    iossim_device_handle *handle,
    const uint8_t *host_name, size_t host_name_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_create_remote_pairing(
    iossim_device_handle *handle,
    const uint8_t *hostname, size_t hostname_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_validate_remote_pairing(
    iossim_device_handle *handle,
    const uint8_t *hostname, size_t hostname_len,
    const uint8_t *pairing_bytes, size_t pairing_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_developer_support_status(
    iossim_device_handle *handle,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_mount_developer_support(
    iossim_device_handle *handle,
    const uint8_t *image_path,
    size_t image_path_len,
    const uint8_t *trust_cache_path,
    size_t trust_cache_path_len,
    const uint8_t *build_manifest_path,
    size_t build_manifest_path_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_app_inventory(iossim_device_handle *handle, uint64_t timeout_ms);
iossim_bridge_result *iossim_bridge_install_app(
    iossim_device_handle *handle, const uint8_t *local_path, size_t local_path_len,
    bool upgrade, uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_uninstall_app(
    iossim_device_handle *handle, const uint8_t *bundle_id, size_t bundle_id_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_launch_app(
    iossim_device_handle *handle, const uint8_t *bundle_id, size_t bundle_id_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_developer_services_status(
    iossim_device_handle *handle,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_container_write(
    iossim_device_handle *handle,
    const uint8_t *bundle_id, size_t bundle_id_len,
    const uint8_t *relative_path, size_t relative_path_len,
    const uint8_t *bytes, size_t bytes_len,
    uint64_t timeout_ms
);
iossim_bridge_result *iossim_bridge_container_read(
    iossim_device_handle *handle,
    const uint8_t *bundle_id, size_t bundle_id_len,
    const uint8_t *relative_path, size_t relative_path_len,
    uint64_t timeout_ms
);
void iossim_bridge_cancel(iossim_device_handle *handle);
void iossim_bridge_close_device(iossim_device_handle *handle);
void iossim_bridge_result_free(iossim_bridge_result *result);

#ifdef __cplusplus
}
#endif
#endif
