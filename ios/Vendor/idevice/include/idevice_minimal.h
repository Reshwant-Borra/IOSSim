// Minimal IOSSim bindings for jkcoxson/idevice FFI.
// Source pin: https://github.com/jkcoxson/idevice
// Commit: c442bd235bd14d6d5c8f28f85c9e6179e3a4c3d5

#ifndef IOSSIM_IDEVICE_MINIMAL_H
#define IOSSIM_IDEVICE_MINIMAL_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/types.h>

typedef socklen_t idevice_socklen_t;
typedef struct sockaddr idevice_sockaddr;

typedef struct AdapterHandle AdapterHandle;
typedef struct DeviceInfoHandle DeviceInfoHandle;
typedef struct LocationSimulationHandle LocationSimulationHandle;
typedef struct RemoteServerHandle RemoteServerHandle;
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;

typedef struct IdeviceFfiError {
  int32_t code;
  int32_t sub_code;
  const char *message;
} IdeviceFfiError;

IdeviceFfiError *rp_pairing_file_read(const char *path, RpPairingFileHandle **out);
void rp_pairing_file_free(RpPairingFileHandle *handle);

IdeviceFfiError *tunnel_create_rppairing(const idevice_sockaddr *addr,
                                         idevice_socklen_t addr_len,
                                         const char *hostname,
                                         RpPairingFileHandle *pairing_file,
                                         const char *(*pin_callback)(void *context),
                                         void *pin_context,
                                         AdapterHandle **out_adapter,
                                         RsdHandshakeHandle **out_handshake);

IdeviceFfiError *remote_server_connect_rsd(AdapterHandle *provider,
                                           RsdHandshakeHandle *handshake,
                                           RemoteServerHandle **handle);
void remote_server_free(RemoteServerHandle *handle);

IdeviceFfiError *device_info_new(RemoteServerHandle *server, DeviceInfoHandle **handle);
IdeviceFfiError *device_info_directory_listing(DeviceInfoHandle *handle,
                                               const char *path,
                                               char ***entries_out,
                                               uintptr_t *count_out);
void device_info_string_array_free(char **strings, uintptr_t count);
void device_info_free(DeviceInfoHandle *handle);

IdeviceFfiError *location_simulation_new(RemoteServerHandle *server,
                                         LocationSimulationHandle **handle);
IdeviceFfiError *location_simulation_set(LocationSimulationHandle *handle,
                                         double latitude,
                                         double longitude);
IdeviceFfiError *location_simulation_clear(LocationSimulationHandle *handle);
void location_simulation_free(LocationSimulationHandle *handle);

void rsd_handshake_free(RsdHandshakeHandle *handle);
void adapter_free(AdapterHandle *handle);
void idevice_error_free(IdeviceFfiError *err);

#endif
