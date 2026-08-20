#include "input.h"
#include "qemu_abi.h"
#include "fb.h"
#include "renderer.h"

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0006
#define LOG_TAG "QemuInput"

extern QemuConsole *g_qemu_con; /* vm.cpp */

static int s_buttons;

void input_send_pointer(int viewX, int viewY, int buttons)
{
    if (!g_qemu_con || !qe_input_queue_abs) {
        return;
    }
    int fw, fh;
    {
        std::lock_guard<std::mutex> lock(g_fb.mu);
        fw = g_fb.w;
        fh = g_fb.h;
    }
    if (fw <= 0 || fh <= 0) {
        return;
    }
    /* view px -> guest framebuffer px through the letterbox viewport */
    int vpX, vpY, vpW, vpH;
    renderer_get_viewport(&vpX, &vpY, &vpW, &vpH);
    int x, y;
    if (vpW > 0 && vpH > 0) {
        x = (int)((int64_t)(viewX - vpX) * fw / vpW);
        y = (int)((int64_t)(viewY - vpY) * fh / vpH);
    } else {
        x = viewX;
        y = viewY;
    }
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= fw) x = fw - 1;
    if (y >= fh) y = fh - 1;

    qe_input_queue_abs(g_qemu_con, INPUT_AXIS_X, x, 0, fw - 1);
    qe_input_queue_abs(g_qemu_con, INPUT_AXIS_Y, y, 0, fh - 1);

    static const struct { int mask; int btn; } kBtns[] = {
        {0x01, INPUT_BUTTON_LEFT},
        {0x02, INPUT_BUTTON_RIGHT},
        {0x04, INPUT_BUTTON_MIDDLE},
    };
    int diff = s_buttons ^ buttons;
    for (const auto &b : kBtns) {
        if (diff & b.mask) {
            qe_input_queue_btn(g_qemu_con, b.btn, (buttons & b.mask) != 0);
        }
    }
    s_buttons = buttons;
    qe_input_event_sync();
}

void input_send_key(int qcode, bool down)
{
    if (!qe_input_send_key) {
        return;
    }
    qe_input_send_key(nullptr, qcode, down);
}
