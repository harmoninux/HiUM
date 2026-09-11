// Serial bridge: one AF_UNIX *client* per VM, connecting to the socket that
// qemu's `-serial chardev:socket,server=on` listens on (filesDir/vm/serial-<vmId>.sock).
// QEMU is the server; we connect from a reader thread, push inbound bytes to
// ArkTS through a per-VM napi threadsafe function and accept outbound writes.
// Mirrors qmp.cpp's per-VM QmpState idiom — all ArkUI windows share the process
// registry, so VmConsole can open/close the same VM serial from any window.
#ifndef SERIAL_H
#define SERIAL_H

#include "napi/native_api.h"
#include <string>

/* spawn the connector/reader thread for vmId; retries until qemu listens on
 * sockPath. returns 0 if the thread was (or already is) running. */
int serial_open(const std::string &vmId, const std::string &sockPath);

/* write text to the VM's serial port (UTF-8 / ASCII bytes). returns bytes
 * written, or -1 when not connected. */
int serial_write(const std::string &vmId, const std::string &text);

/* close the connection and stop the reader thread (VM's chardev survives;
 * a later serial_open reconnects, server=on accepts again). */
void serial_close(const std::string &vmId);

/* register (or clear, with nullptr) the ArkTS data callback for one VM;
 * invoked with raw text of every inbound chunk, plus a synthetic
 * <SERIAL_DISCONNECT> marker when the socket dies. */
void serial_set_callback(const std::string &vmId, napi_env env, napi_value cb);

#endif /* SERIAL_H */
