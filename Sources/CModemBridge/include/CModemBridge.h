#ifndef C_MODEM_BRIDGE_H
#define C_MODEM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CellDockModem CellDockModem;
typedef struct CellDockVoice CellDockVoice;

typedef struct CellDockModemDevice {
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;
    uint64_t registry_id;
} CellDockModemDevice;
typedef void (*CellDockModemStreamCallback)(
    void *context,
    const uint8_t *bytes,
    size_t length
);

enum {
    CELLDOCK_MODEM_OK = 0,
    CELLDOCK_MODEM_NOT_FOUND = 1,
    CELLDOCK_MODEM_NOT_OPEN = 2,
    CELLDOCK_MODEM_BUFFER_TOO_SMALL = 3
};

CellDockModem *celldock_modem_create(void);
void celldock_modem_destroy(CellDockModem *modem);

/*
 * Copies every supported physical USB modem currently present in IOKit.
 * The return value is the total number found, which may exceed capacity.
 * Passing NULL with capacity 0 performs a count-only scan.
 */
size_t celldock_modem_copy_devices(CellDockModemDevice *devices, size_t capacity);

/*
 * Returns 1 for USB identities whose AT interface 2 CellDock can open:
 * Quectel QDC507 (2C7C:0125), Quectel RM520N-GL (2C7C:0801) and the
 * Baiwang module (2CA3:4006). Pure predicate; it does not touch IOKit.
 */
int celldock_modem_is_supported_identity(uint16_t vendor_id, uint16_t product_id);

/*
 * Copies the raw USB string descriptors published by the physical device at
 * location_id. Output buffers are always NUL-terminated when their capacity
 * is greater than zero. Returns 1 when the device was found, otherwise zero.
 */
int celldock_modem_copy_usb_names(
    uint32_t location_id,
    char *vendor_name,
    size_t vendor_name_capacity,
    char *product_name,
    size_t product_name_capacity
);

/*
 * Opens only IOUSBHostInterface 2, never the parent device or ECM interface,
 * and establishes a quiet AT protocol boundary before returning.
 */
int celldock_modem_open(CellDockModem *modem);
int celldock_modem_open_for_location(CellDockModem *modem, uint32_t location_id);
void celldock_modem_close(CellDockModem *modem);
int celldock_modem_is_open(const CellDockModem *modem);

/*
 * Aborts only a pending unsolicited-event/resynchronization read, without
 * resetting or closing the USB interface. Command and SMS response reads are
 * never interrupted. Calling this with no interruptible read is a safe no-op.
 */
int celldock_modem_interrupt_read(CellDockModem *modem);

uint16_t celldock_modem_vendor_id(const CellDockModem *modem);
uint16_t celldock_modem_product_id(const CellDockModem *modem);
uint32_t celldock_modem_location_id(const CellDockModem *modem);
uint64_t celldock_modem_registry_id(const CellDockModem *modem);
uint8_t celldock_modem_input_endpoint(const CellDockModem *modem);
uint8_t celldock_modem_output_endpoint(const CellDockModem *modem);
void celldock_modem_set_stream_callback(
    CellDockModem *modem,
    CellDockModemStreamCallback callback,
    void *context
);

/*
 * Sends one ASCII AT command and waits for OK/ERROR. The response is always
 * NUL-terminated when output_capacity is greater than zero. A timeout,
 * transport error, or malformed/oversized response closes the AT interface;
 * callers must reopen it before issuing another command.
 */
int celldock_modem_command(
    CellDockModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

/* Dial/answer commands may finish with a call result instead of OK/ERROR. */
int celldock_modem_call_command(
    CellDockModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

/*
 * Submits one SMS-SUBMIT PDU using the two-stage AT+CMGS prompt protocol.
 * pdu must contain ASCII hexadecimal digits including the SMSC length octet;
 * tpdu_length excludes that SMSC field, as required by AT+CMGS.
 *
 * The payload is never written unless a '>' prompt is observed. After the
 * payload and Ctrl-Z are written, a timeout is intentionally ambiguous and
 * closes the interface so callers cannot accidentally retry the same SMS.
 */
int celldock_modem_send_sms_pdu(
    CellDockModem *modem,
    const char *pdu,
    size_t tpdu_length,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

/*
 * Reads already pending unsolicited bytes. Timeout is intentionally short.
 * Bytes observed while establishing a quiet protocol boundary are returned
 * here before new USB reads, so resynchronization cannot swallow URCs. A
 * non-timeout transport/protocol error closes the AT interface.
 */
int celldock_modem_read(
    CellDockModem *modem,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

const char *celldock_modem_last_error(const CellDockModem *modem);

/*
 * Whether a result code from the command functions means "no terminal
 * response arrived in time". Callers use it to tell a slow network apart
 * from a broken USB transport without parsing the English error text.
 */
int celldock_modem_result_is_timeout(int result);

/*
 * Raw voice-over-USB transport for QPCMV option 0. This opens only USB
 * interface 1 (the NMEA/PCM port); it never opens or resets the parent USB
 * device and therefore can run alongside the AT and CDC-ECM interfaces.
 */
CellDockVoice *celldock_voice_create(void);
void celldock_voice_destroy(CellDockVoice *voice);
int celldock_voice_open(CellDockVoice *voice);
int celldock_voice_open_for_location(CellDockVoice *voice, uint32_t location_id);
int celldock_voice_open_interface(CellDockVoice *voice, uint8_t interface_number);
int celldock_voice_open_interface_for_location(
    CellDockVoice *voice,
    uint32_t location_id,
    uint8_t interface_number
);
/*
 * Opens a specific control interface and, if another user-space client owns
 * it, asks IOKit to transfer exclusive access. Intended for the module's ADB
 * interface only; AT, ECM and audio callers should keep using normal opens.
 */
int celldock_voice_open_control_interface_for_location(
    CellDockVoice *voice,
    uint32_t location_id,
    uint8_t interface_number
);

/*
 * Reads the process owner recorded by IOUSBHostInterface as
 * "pid <number>, <name>". Returns 1 when a process owner is present, otherwise
 * zero. This does not open, close, seize, or otherwise mutate the interface.
 */
int celldock_usb_interface_owner_process(
    uint32_t location_id,
    uint8_t interface_number,
    int32_t *process_id,
    char *process_name,
    size_t process_name_capacity
);
void celldock_voice_close(CellDockVoice *voice);
int celldock_voice_is_open(const CellDockVoice *voice);

uint8_t celldock_voice_input_endpoint(const CellDockVoice *voice);
uint8_t celldock_voice_output_endpoint(const CellDockVoice *voice);

/* Clears a recoverable USB endpoint halt without resetting the device. */
int celldock_voice_clear_stalls(CellDockVoice *voice);

/*
 * A successful read returns the number of PCM bytes received; a timeout
 * returns zero. Writes return CELLDOCK_MODEM_OK on success. Any other return value
 * is an IOKit/bridge error and closes the voice interface.
 */
int celldock_voice_read(
    CellDockVoice *voice,
    int timeout_ms,
    uint8_t *output,
    size_t output_capacity
);
int celldock_voice_write(
    CellDockVoice *voice,
    int timeout_ms,
    const uint8_t *bytes,
    size_t length
);

const char *celldock_voice_last_error(const CellDockVoice *voice);

#ifdef __cplusplus
}
#endif

#endif
