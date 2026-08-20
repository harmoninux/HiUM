#ifndef INPUT_H
#define INPUT_H

/* absolute pointer: x/y in guest framebuffer pixels, buttons bitmask:
 * bit0 left, bit1 right, bit2 middle (matches MOUSE_EVENT_* in console.h) */
void input_send_pointer(int x, int y, int buttons);
void input_send_key(int qcode, bool down);

#endif /* INPUT_H */
