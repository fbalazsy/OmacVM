/* Run the actual submit wrapper against inert libusb. */
struct libusb_transfer { int dummy; };
static int submit_calls, submit_error;
#define LIBUSB_ERROR_BUSY -6
static int libusb_submit_transfer(struct libusb_transfer *t)
{
    submit_calls++;
    return submit_error;
}
/* WRAPPER */
int main(void)
{
    USBHostDevice s = { .hostfd = -1, .dh = &handles[0] };
    struct libusb_transfer transfer = {0};
    uint64_t epoch;
    s.session = usb_host_session_acquire(&devices[0]);
    assert(s.session);
    assert(usb_host_submit_transfer(&s, &transfer) == 0);
    assert(submit_calls == 1);
    assert(usb_host_session_freeze(&devices[0], &epoch));
    assert(usb_host_submit_transfer(&s, &transfer) == LIBUSB_ERROR_BUSY);
    usb_host_session_release(&s.session);
    assert(!usb_host_session_drained(100, epoch));
    usb_host_session_complete(&transfer);
    assert(usb_host_session_drained(100, epoch));
    s.session = usb_host_session_acquire(&devices[1]);
    submit_error = -1;
    assert(usb_host_submit_transfer(&s, &transfer) == -1);
    assert(usb_host_session_freeze(&devices[1], &epoch));
    usb_host_session_release(&s.session);
    assert(usb_host_session_drained(200, epoch));
    puts("PASS actual submit wrapper: freeze, live completion, failed-submit rollback");
}
