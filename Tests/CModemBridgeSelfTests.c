#include "CModemBridge.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    char vendor_name[64] = "unexpected";
    char product_name[64] = "unexpected";
    assert(celldock_modem_copy_usb_names(
        0,
        vendor_name,
        sizeof(vendor_name),
        product_name,
        sizeof(product_name)
    ) == 0);
    assert(vendor_name[0] == '\0');
    assert(product_name[0] == '\0');

    assert(celldock_modem_is_supported_identity(0x2C7C, 0x0125) == 1);
    assert(celldock_modem_is_supported_identity(0x2C7C, 0x0801) == 1);
    assert(celldock_modem_is_supported_identity(0x2CA3, 0x4006) == 1);
    assert(celldock_modem_is_supported_identity(0x2C7C, 0x0800) == 0);
    assert(celldock_modem_is_supported_identity(0x2C7C, 0x0802) == 0);
    assert(celldock_modem_is_supported_identity(0x2CA3, 0x0801) == 0);
    assert(celldock_modem_is_supported_identity(0x0000, 0x0000) == 0);

    assert(celldock_modem_result_is_timeout((int)0xE0004051) == 1);
    assert(celldock_modem_result_is_timeout((int)0xE00002D6) == 1);
    assert(celldock_modem_result_is_timeout(CELLDOCK_MODEM_OK) == 0);
    assert(celldock_modem_result_is_timeout(CELLDOCK_MODEM_NOT_OPEN) == 0);
    assert(celldock_modem_result_is_timeout(CELLDOCK_MODEM_NOT_FOUND) == 0);

    size_t discovered_count = celldock_modem_copy_devices(NULL, 0);
    CellDockModemDevice discovered[8] = {0};
    size_t copied_count = celldock_modem_copy_devices(discovered, 8);
    assert(copied_count == discovered_count);
    size_t inspected_count = copied_count < 8 ? copied_count : 8;
    for (size_t index = 0; index < inspected_count; index++) {
        assert(discovered[index].location_id != 0);
        assert(celldock_modem_is_supported_identity(
            discovered[index].vendor_id,
            discovered[index].product_id
        ) == 1);
        assert(celldock_modem_copy_usb_names(
            discovered[index].location_id,
            vendor_name,
            sizeof(vendor_name),
            product_name,
            sizeof(product_name)
        ) == 1);
        if (index > 0) {
            assert(discovered[index - 1].location_id < discovered[index].location_id);
        }
    }

    int32_t owner_pid = -1;
    char owner_name[32] = "unexpected";
    assert(celldock_usb_interface_owner_process(
        0,
        6,
        &owner_pid,
        owner_name,
        sizeof(owner_name)
    ) == 0);
    assert(owner_pid == 0);
    assert(owner_name[0] == '\0');

    CellDockModem *modem = celldock_modem_create();
    assert(modem != NULL);
    assert(celldock_modem_is_open(modem) == 0);
    assert(celldock_modem_interrupt_read(modem) == CELLDOCK_MODEM_NOT_OPEN);
    celldock_modem_close(modem);
    celldock_modem_destroy(modem);
    printf(
        "CModemBridge self-tests passed (discovery=%zu, lifecycle and idle read interruption).\n",
        discovered_count
    );
    return 0;
}
