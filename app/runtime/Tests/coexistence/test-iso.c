struct libusb_transfer { void *user_data; void *buffer; };
typedef struct { USBHostDevice *host; } USBHostIsoRing;
typedef struct { USBHostIsoRing *ring; struct libusb_transfer *xfer; } USBHostIsoXfer;
static int freed;
static void libusb_free_transfer(struct libusb_transfer *transfer) { freed++; free(transfer); }
/* WRAPPER */
int main(void)
{
    USBHostDevice s = { .hostfd = -1 };
    USBHostIsoRing ring = { .host = &s };
    USBHostIsoXfer *x = calloc(1, sizeof(*x));
    struct libusb_transfer *transfer = calloc(1, sizeof(*transfer));
    uint64_t epoch;
    x->ring = &ring;
    x->xfer = transfer;
    transfer->user_data = x;
    s.session = usb_host_session_acquire(&devices[0]);
    assert(usb_host_session_submit(s.session, transfer));
    assert(usb_host_session_freeze(&devices[0], &epoch));
    usb_host_iso_free_xfer(x, true);
    assert(!transfer->user_data && !freed);
    usb_host_session_release(&s.session);
    assert(!usb_host_session_drained(100, epoch));
    usb_host_session_complete(transfer);
    /* Completion clears the counter, not the uncertainty of orphan cleanup. */
    assert(!usb_host_session_drained(100, epoch));
    libusb_free_transfer(transfer);
    puts("PASS actual ISO orphan free: late completion cannot bless cleanup");
}
