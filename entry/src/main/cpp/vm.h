// VM lifecycle: dlopen the qemu .so, resolve the internal entry points we
// need, run qemu_system_entry on its own thread, then bind our display
// change listener once the default console exists.
#ifndef VM_H
#define VM_H

#include <string>
#include <vector>

/* arch: "x86_64" | "i386" | "aarch64"; args: qemu cmdline without argv[0].
 * returns 0 on success, -1 on error/busy, -2 when the qemu lib is spent
 * and the process must be restarted before running another VM */
int vm_start(const std::string &arch, const std::vector<std::string> &args);
bool vm_running();

/* true once a VM run has completed in this process (lib no longer re-usable) */
bool vm_spent();

#endif /* VM_H */
