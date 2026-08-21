// Minimal QMP client. qemu is started with `-qmp tcp:127.0.0.1:PORT,...`;
// we connect from a reader thread, serialize commands (one in flight) and
// forward async events to ArkTS through a napi threadsafe function.
#ifndef QMP_H
#define QMP_H

#include "napi/native_api.h"
#include <string>

/* spawn the connector/reader thread; retries until qemu starts listening.
 * returns 0 if the thread was (or already is) running. */
int qmp_connect(int port);

/* execute one QMP command (JSON without trailing newline), blocking up to a
 * few seconds for the matching response. returns the raw JSON response, or
 * an empty string on timeout / not connected. */
std::string qmp_command(const std::string &json);

/* close the connection and stop the reader thread */
void qmp_disconnect();

/* true while the socket is live */
bool qmp_connected();

/* register (or clear, with nullptr) the ArkTS event callback; invoked with
 * the raw JSON of every QMP async event, plus a synthetic
 * {"event":"QMP_DISCONNECT"} when the socket dies */
void qmp_set_event_callback(napi_env env, napi_value cb);

#endif /* QMP_H */
