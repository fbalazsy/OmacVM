#include "review-test-base.inc"
int main(void)
{
    const char *args[] = {"policy", "-machine", "none", "-accel", "qtest", "-nodefaults",
                         "-no-user-config", "-display", "none", "-net", "none", "-S", NULL};
    char *argv[13];
    for (int i = 0; i < 13; i++) { argv[i] = g_strdup(args[i]); }
    qemu_init(12, argv);
    policy_load();
    USBDevice *d = USB_DEVICE(qdev_new("usb-host-hid"));
    qdev_prop_set_uint64(&d->qdev, "registry-id", 123);
    qdev_prop_set_uint16(&d->qdev, "vendorid", 49745);
    qdev_prop_set_uint16(&d->qdev, "productid", 5889);
    g_autofree char *serial = text(field(scope_nodes[1].props, "SerialNumber"));
    qdev_prop_set_string(&d->qdev, "serial", serial);
    Error *err = NULL;
    bool ok = native_open(HOST_HID(d), &err);
    bool expected = CFBooleanGetValue(field(policy_case, "native"));
    unsigned create = integer(field(policy_case, "create"));
    unsigned open = integer(field(policy_case, "open"));
    bool pass = ok == expected && scope_created == create && review_open_attempts == open;
    printf("%s %s expected=%d actual=%d create=%u/%u open=%d/%u error=%s\n",
           pass ? "PASS" : "FAIL", getenv("REVIEW_CASE"), expected, ok, scope_created,
           create, review_open_attempts, open, err ? error_get_pretty(err) : "none");
    if (ok) { native_close(HOST_HID(d)); }
    g_clear_pointer(&HOST_HID(d)->product, g_free);
    if (err) { error_free(err); }
    object_unref(d);
    return pass ? 0 : 1;
}
