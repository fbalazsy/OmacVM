/* Exact ordinary and HMP function bodies, all device APIs inert. */
int main(int argc, char **argv)
{
    uint64_t epoch;
    USBHostDevice s = { .hostfd = -1 };
    assert(usb_host_session_freeze(&devices[0], &epoch));
    if (!strcmp(argv[1], "ordinary")) {
        assert(usb_host_open(&s, &devices[0], 0) < 0);
        assert(opens[0] == 0);
        assert(usb_host_open(&s, &devices[1], 0) == 0);
        assert(opens[1] == 1 && requests[1] == 1);
        usb_host_close(&s);
        assert(closes[1] == 1);
    } else if (!strcmp(argv[1], "hmp")) {
        hmp_info_usbhost(NULL, NULL);
        assert(opens[0] == 0 && opens[1] == 1 && opens[2] == 1);
        assert(requests[1] == 1 && requests[2] == 1);
    } else if (!strcmp(argv[1], "timeout")) {
        USBHostRequest r = { .host = &s };
        assert(usb_host_open(&s, &devices[1], 0) == 0);
        assert(usb_host_session_freeze(&devices[1], &epoch));
        s.requests = &r;
        usb_host_abort_xfers(&s);
        assert(events == 100 && !s.requests);
        usb_host_close(&s);
        assert(!usb_host_session_drained(200, epoch));
        assert(!r.host);
    } else {
        fail_open = !strcmp(argv[1], "open-error");
        fail_attach = !strcmp(argv[1], "attach-error");
        fail_detach = !strcmp(argv[1], "detach-error");
        assert(usb_host_open(&s, &devices[1], 0) < 0);
        assert(!s.session);
        assert(usb_host_session_freeze(&devices[1], &epoch));
        assert(usb_host_session_drained(200, epoch));
    }
    puts(argv[1]);
    return 0;
}
