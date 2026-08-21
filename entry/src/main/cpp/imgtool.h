#pragma once

#include <string>
#include <vector>

/* 跑一条 qemu-img 命令（qemu_img_entry 不可再入，必须一进程一条命令）。
 * 这里 fork 一个一次性子进程：子进程 dlopen libqemu-img.so 调 qemu_img_entry
 * 一次后 _exit；父进程经 pipe 捕获其 stdout+stderr 并 waitpid。
 * out 收集子进程输出（info/help 等要读文本；命令本身错误信息也在 stderr）。
 * 返回子进程退出码；fork/pipe 拉起失败返回负数。 */
int imgtool_run(const std::vector<std::string> &args, std::string &out);
