#ifndef IOSSIM_DEVICE_BRIDGE_H
#define IOSSIM_DEVICE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
#define IOSSIM_DEVICE_BRIDGE_ABI_VERSION 1u

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
    IOSSIM_BRIDGE_INTERNAL_ERROR = 11
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
    uint64_t connection_generation,
    uint64_t timeout_ms,
    iossim_device_handle **out_handle
);
iossim_bridge_result *iossim_bridge_inspect_device(
    iossim_device_handle *handle,
    uint64_t timeout_ms
);
void iossim_bridge_cancel(iossim_device_handle *handle);
void iossim_bridge_close_device(iossim_device_handle *handle);
void iossim_bridge_result_free(iossim_bridge_result *result);

#ifdef __cplusplus
}
#endif
#endif
