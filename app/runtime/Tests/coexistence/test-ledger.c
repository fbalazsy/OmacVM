/* Hardware-free tests of the production coordinator, not a second model. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef struct libusb_device { uint64_t session; int refs; } libusb_device;
static uint64_t libusb_get_session_data(libusb_device *d) { return d->session; }
static libusb_device *libusb_ref_device(libusb_device *d) { __atomic_add_fetch(&d->refs, 1, __ATOMIC_SEQ_CST); return d; }
static void libusb_unref_device(libusb_device *d) { __atomic_sub_fetch(&d->refs, 1, __ATOMIC_SEQ_CST); }
#define g_new0(t, n) ((t *)calloc((n), sizeof(t)))
#define g_free free
#include "host-coexistence.c"
static pthread_mutex_t test_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t test_cond = PTHREAD_COND_INITIALIZER;
static int ready;
static libusb_device concurrent = { .session = 40 };
static void *worker(void *unused)
{
    (void)unused;
    USBHostSession *s = usb_host_session_acquire(&concurrent);
    int transfer = 0;
    assert(s && usb_host_session_submit(s, &transfer));
    pthread_mutex_lock(&test_lock);
    ready = 1;
    pthread_cond_broadcast(&test_cond);
    while (ready != 2) {
        pthread_cond_wait(&test_cond, &test_lock);
    }
    pthread_mutex_unlock(&test_lock);
    assert(!usb_host_session_submit(s, &concurrent));
    usb_host_session_release(&s);
    usb_host_session_complete(&transfer);
    return NULL;
}
int main(void)
{
    pthread_t thread;
    uint64_t concurrent_epoch;
    assert(!pthread_create(&thread, NULL, worker, NULL));
    pthread_mutex_lock(&test_lock);
    while (!ready) {
        pthread_cond_wait(&test_cond, &test_lock);
    }
    assert(usb_host_session_freeze(&concurrent, &concurrent_epoch));
    assert(!usb_host_session_drained(40, concurrent_epoch));
    ready = 2;
    pthread_cond_broadcast(&test_cond);
    pthread_mutex_unlock(&test_lock);
    assert(!pthread_join(thread, NULL));
    assert(usb_host_session_drained(40, concurrent_epoch));
    assert(!usb_host_session_drained(40, concurrent_epoch + 1));
    assert(!usb_host_session_freeze(&concurrent, &concurrent_epoch));
    puts("PASS real pthread freeze vs handle/transfer completion; replay rejected");
    libusb_device a = { .session = 10 }, b = { .session = 20 };
    USBHostSession *ha = usb_host_session_acquire(&a);
    USBHostSession *hb;
    uint64_t epoch = 0;
    assert(ha && a.refs == 1);
    assert(usb_host_session_freeze(&a, &epoch) && epoch);
    assert(!usb_host_session_acquire(&a));
    assert(!usb_host_session_drained(10, epoch));
    hb = usb_host_session_acquire(&b);
    assert(hb);
    usb_host_session_release(&ha);
    assert(usb_host_session_drained(10, epoch));
    usb_host_session_release(&hb);
    puts("PASS freeze excludes A handles; B unchanged; exact close drains");
    libusb_device c = { .session = 30 };
    USBHostSession *hc = usb_host_session_acquire(&c);
    int transfer = 0;
    assert(usb_host_session_submit(hc, &transfer));
    assert(usb_host_session_freeze(&c, &epoch));
    assert(!usb_host_session_submit(hc, &a));
    usb_host_session_release(&hc);
    assert(!usb_host_session_drained(30, epoch));
    usb_host_session_complete(&transfer);
    assert(usb_host_session_drained(30, epoch));
    libusb_device poison = { .session = 31 };
    USBHostSession *hp = usb_host_session_acquire(&poison);
    assert(hp);
    usb_host_session_uncertain(hp);
    assert(!usb_host_session_submit(hp, &poison));
    assert(!usb_host_session_acquire(&poison));
    usb_host_session_release(&hp);
    uint64_t c_epoch = epoch;
    libusb_device mismatch = { .session = 20 };
    assert(!usb_host_session_acquire(&mismatch));
    assert(usb_host_session_freeze(&b, &epoch));
    assert(!usb_host_session_drained(20, epoch));
    puts("PASS conflicting pointer for published session poisons receipt");
    usb_host_session_complete(&transfer); /* unmatched completion poisons all */
    assert(!usb_host_session_drained(30, c_epoch));
    puts("PASS late/orphan completion retained through handle close; replay poisons");
    return 0;
}
