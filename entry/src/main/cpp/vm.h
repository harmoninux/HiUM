// VM lifecycle: dlopen the qemu .so, resolve the internal entry points we
// need, run qemu_system_entry on its own thread, then bind our display
// change listener once the default console exists.
#ifndef VM_H
#define VM_H

#include <string>
#include <vector>

/* arch: "x86_64" | "i386" | "aarch64"; args: qemu cmdline without argv[0] */
int vm_start(const std::string &arch, const std::vector<std::string> &args);
bool vm_running();

#endif /* VM_H */
