// Minimal QMP client, one connection per VM. qemu is started with
// `-qmp unix:<vmDataDir>/qmp-<vmId>.sock,...`（unix socket 没有端口冲突问题）;
// we connect from a reader thread, serialize commands (one in flight) and
// forward async events to ArkTS through a per-VM napi threadsafe function.
#ifndef QMP_H
#define QMP_H

#include "napi/native_api.h"
#include <string>

/* spawn the connector/reader thread for vmId; retries until qemu starts
 * listening on sockPath. returns 0 if the thread was (or already is) running. */
int qmp_connect(const std::string &vmId, const std::string &sockPath);

/* execute one QMP command (JSON without trailing newline), blocking up to a
 * few seconds for the matching response. returns the raw JSON response, or
 * an empty string on timeout / not connected. */
std::string qmp_command(const std::string &vmId, const std::string &json);

/* close the connection and stop the reader thread */
void qmp_disconnect(const std::string &vmId);

/* true while the socket is live */
bool qmp_connected(const std::string &vmId);

/* register (or clear, with nullptr) the ArkTS event callback for one VM;
 * invoked with the raw JSON of every QMP async event, plus a synthetic
 * {"event":"QMP_DISCONNECT"} when the socket dies */
void qmp_set_event_callback(const std::string &vmId, napi_env env, napi_value cb);

#endif /* QMP_H */
