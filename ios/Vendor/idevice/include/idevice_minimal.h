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
typedef struct XCTestRunnerHandle XCTestRunnerHandle;

typedef struct IdeviceFfiError {
  int32_t code;
  int32_t sub_code;
  const char *message;
} IdeviceFfiError;

typedef enum XCTestRunnerStatus {
  XCTEST_RUNNER_STATUS_UNKNOWN = 0,
  XCTEST_RUNNER_STATUS_RSD_READY = 1,
  XCTEST_RUNNER_STATUS_TESTMANAGER_CONTROL_READY = 2,
  XCTEST_RUNNER_STATUS_TESTMANAGER_MAIN_READY = 3,
  XCTEST_RUNNER_STATUS_DVT_READY = 4,
  XCTEST_RUNNER_STATUS_RUNNER_LAUNCHED = 5,
  XCTEST_RUNNER_STATUS_PID_AUTHORIZED = 6,
  XCTEST_RUNNER_STATUS_XCTEST_HANDSHAKE_READY = 7,
  XCTEST_RUNNER_STATUS_TEST_PLAN_STARTED = 8,
  XCTEST_RUNNER_STATUS_FINISHED = 9,
  XCTEST_RUNNER_STATUS_FAILED = 10
} XCTestRunnerStatus;

typedef struct XCTestRunnerConfig {
  const char *runner_bundle_id;
  const char *runner_app_path;
  const char *runner_app_container;
  const char *runner_bundle_executable;
  const char *target_bundle_id;
  const char *target_app_path;
  const char *const *env_vars;
  uintptr_t env_vars_count;
  const char *const *arguments;
  uintptr_t arguments_count;
} XCTestRunnerConfig;

typedef struct XCTestRunnerMetadata {
  char *runner_bundle_id;
  char *runner_app_path;
  char *runner_app_container;
  char *runner_bundle_executable;
} XCTestRunnerMetadata;

typedef void (*XCTestRunnerStatusCallback)(void *context,
                                           XCTestRunnerStatus status,
                                           const char *message);

IdeviceFfiError *rp_pairing_file_read(const char *path, RpPairingFileHandle **out);
IdeviceFfiError *rp_pairing_file_to_bytes(RpPairingFileHandle *handle,
                                          uint8_t **out_data,
                                          uintptr_t *out_len);
void rp_pairing_file_free(RpPairingFileHandle *handle);
void idevice_data_free(uint8_t *data, uintptr_t len);

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

IdeviceFfiError *xctest_runner_new_from_rsd(AdapterHandle *adapter,
                                            RsdHandshakeHandle *handshake,
                                            uint8_t ios_major_version,
                                            XCTestRunnerStatusCallback callback,
                                            void *callback_context,
                                            XCTestRunnerHandle **out);
IdeviceFfiError *xctest_runner_copy_metadata_from_rsd(AdapterHandle *adapter,
                                                      RsdHandshakeHandle *handshake,
                                                      const char *bundle_id,
                                                      XCTestRunnerMetadata **out);
IdeviceFfiError *xctest_runner_start(XCTestRunnerHandle *handle,
                                     const XCTestRunnerConfig *config,
                                     double timeout_seconds);
IdeviceFfiError *xctest_runner_stop(XCTestRunnerHandle *handle);
IdeviceFfiError *xctest_runner_get_status(XCTestRunnerHandle *handle,
                                          XCTestRunnerStatus *status_out,
                                          XCTestRunnerStatus *first_error_stage_out);
char *xctest_runner_copy_error_message(XCTestRunnerHandle *handle);
void xctest_runner_string_free(char *string);
void xctest_runner_metadata_free(XCTestRunnerMetadata *metadata);
void xctest_runner_free(XCTestRunnerHandle *handle);

void rsd_handshake_free(RsdHandshakeHandle *handle);
void adapter_free(AdapterHandle *handle);
void idevice_error_free(IdeviceFfiError *err);

#endif
