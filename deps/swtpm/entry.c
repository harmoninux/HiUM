#include "config.h"
extern int main(int argc, char **argv);
int swtpm_entry(int argc, char **argv);
int swtpm_entry(int argc, char **argv) { return main(argc, argv); }
