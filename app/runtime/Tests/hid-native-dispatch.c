/* Inert native-wrapper regression. No IOHID/IORegistry calls reach IOKit.
 * native.inc is extracted byte-for-byte from the packaged production C by the
 * runner. Only OS boundary calls and QEMU BH/mutex plumbing are substituted.
 * The port model implements Apple's qlimit=1, empty->nonempty input notice,
 * and distinct completion-vs-input receive branches. It is NOT a real device. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#define USB_RET_ASYNC (-6)
#define USB_RET_STALL (-3)
typedef pthread_mutex_t QemuMutex;
typedef struct { void (*callback)(void *); void *opaque; } QEMUBH;
typedef int USBDevice;
typedef int USBPacket;
typedef int USBDesc;
typedef int USBDescDevice;
typedef int USBDescConfig;
typedef int USBDescIface;
typedef int USBDescOther;
typedef int USBDescEndpoint;
typedef struct HostHIDState HostHIDState;
#define qemu_mutex_lock pthread_mutex_lock
#define qemu_mutex_unlock pthread_mutex_unlock
static atomic_int bh_calls;
static dispatch_semaphore_t close_ready;
static unsigned refs=1, late_callbacks;
static pthread_t main_thread;
static bool teardown;
#define HOST_HID(p) ((HostHIDState *)(p))
#define OBJECT(p) (p)
#define g_free free
#define g_clear_pointer(p, fn) do { fn(*(p)); *(p)=NULL; } while (0)
static void native_close(HostHIDState *s);
static void object_ref(HostHIDState *s) { assert(pthread_equal(pthread_self(),main_thread)); refs++; }
static void object_unref(HostHIDState *s) { assert(pthread_equal(pthread_self(),main_thread)); assert(refs==2); refs--; }
static QEMUBH *qemu_bh_new(void (*callback)(void *),void *opaque) {
    QEMUBH *bh=calloc(1,sizeof(*bh)); assert(bh); bh->callback=callback; bh->opaque=opaque; return bh;
}
static void qemu_bh_delete(QEMUBH *bh) { free(bh); }
static void qemu_bh_schedule(QEMUBH *bh) {
    assert(bh); atomic_fetch_add(&bh_calls,1);
    if(bh->callback) dispatch_semaphore_signal(close_ready);
}
static dispatch_queue_t queue;
static dispatch_block_t cancel_handler;
static IOHIDReportCallback input_cb;
static IOHIDCallback removed_cb;
static void *input_ctx;
static unsigned api_calls, sync_calls, completion_calls, input_calls, pending_input;
static unsigned messages[2], nmessages, qlimit=1;
static bool input_first, emit_input=true, hold;
static IOReturn api_result;
static int length_delta;
static dispatch_semaphore_t entered, release_api;
static IOHIDReportCallback done_cb;
static void *done_ctx;
static uint8_t *done_data;
static IOHIDDeviceRef done_device;
static unsigned done_type, done_id;
static CFIndex done_length;
static const char queue_key;
static void notify(unsigned message) { if(nmessages<qlimit) messages[nmessages++]=message; }
static void enqueue_input(void) { if(!pending_input++) notify(2); }
static void drain(void) {
    unsigned count=nmessages; nmessages=0;
    for(unsigned i=0;i<count;i++) {
        if(messages[i]==1) {
            completion_calls++;
            done_cb(done_ctx,api_result,done_device,done_type,done_id,done_data,done_length);
        } else {
            uint8_t report[60]; memset(report,0xa5,sizeof(report));
            while(pending_input) { pending_input--; input_calls++; input_cb(input_ctx,0,NULL,kIOHIDReportTypeInput,0,report,60); }
        }
    }
}
static void set_queue(IOHIDDeviceRef d,dispatch_queue_t q) { queue=q; dispatch_queue_set_specific(q,&queue_key,(void *)&queue_key,NULL); }
static void set_cancel(IOHIDDeviceRef d,dispatch_block_t b) { cancel_handler=Block_copy(b); }
static void cancel_device(IOHIDDeviceRef d) {
    if(teardown) dispatch_async(queue,^{
        uint8_t report[60]={0};
        input_cb(input_ctx,0,NULL,kIOHIDReportTypeInput,0,report,60);
        removed_cb(input_ctx,0,NULL); late_callbacks++;
    });
    dispatch_async(queue,cancel_handler); Block_release(cancel_handler); cancel_handler=NULL;
}
static void register_input(IOHIDDeviceRef d,uint8_t *b,CFIndex n,IOHIDReportCallback cb,void *ctx) { assert(n==64);input_cb=cb;input_ctx=ctx; }
static void register_removed(IOHIDDeviceRef d,IOHIDCallback cb,void *ctx) { removed_cb=cb; }
static void activate(IOHIDDeviceRef d) { }
static IOReturn close_device(IOHIDDeviceRef d,IOOptionBits options) { assert(!options);return 0; }
static IOReturn async_report(IOHIDDeviceRef d,IOHIDReportType t,CFIndex id,uint8_t *b,CFIndex n,CFTimeInterval timeout,IOHIDReportCallback cb,void *ctx) {
    api_calls++; assert(timeout==1000);
    done_cb=cb;done_ctx=ctx;done_data=b;done_device=d;done_type=t;done_id=id;done_length=0;
    if(input_first && emit_input) { enqueue_input();drain(); }
    notify(1);
    if(!input_first && emit_input) enqueue_input();
    dispatch_async(queue,^{drain();});
    return 0;
}
static IOReturn async_set(IOHIDDeviceRef d,IOHIDReportType t,CFIndex id,const uint8_t *b,CFIndex n,CFTimeInterval timeout,IOHIDReportCallback cb,void *ctx) { return async_report(d,t,id,(uint8_t *)b,n,timeout,cb,ctx); }
static IOReturn async_get(IOHIDDeviceRef d,IOHIDReportType t,CFIndex id,uint8_t *b,CFIndex *n,CFTimeInterval timeout,IOHIDReportCallback cb,void *ctx) { IOReturn r=async_report(d,t,id,b,*n,timeout,cb,ctx);done_length=*n+length_delta;return r; }
static IOReturn sync_report(IOHIDDeviceRef d,IOHIDReportType t,CFIndex id,uint8_t *b,CFIndex *n,bool set) {
    assert(dispatch_get_specific(&queue_key)==&queue_key); /* Never QEMU/BQL caller. */
    api_calls++;sync_calls++;dispatch_semaphore_signal(entered);
    if(hold) assert(!dispatch_semaphore_wait(release_api,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
    if(!set) { memset(b,0xa5,*n);*n+=length_delta; }
    if(emit_input) { enqueue_input();dispatch_async(queue,^{drain();}); }
    return api_result;
}
static IOReturn sync_set(IOHIDDeviceRef d,IOHIDReportType t,CFIndex id,const uint8_t *b,CFIndex n) { return sync_report(d,t,id,(uint8_t *)b,&n,true); }
static IOReturn sync_get(IOHIDDeviceRef d,IOHIDReportType t,CFIndex id,uint8_t *b,CFIndex *n) { return sync_report(d,t,id,b,n,false); }
#define IOHIDDeviceSetDispatchQueue set_queue
#define IOHIDDeviceSetCancelHandler set_cancel
#define IOHIDDeviceCancel cancel_device
#define IOHIDDeviceRegisterInputReportCallback register_input
#define IOHIDDeviceRegisterRemovalCallback register_removed
#define IOHIDDeviceActivate activate
#define IOHIDDeviceClose close_device
#define IOHIDDeviceSetReportWithCallback async_set
#define IOHIDDeviceGetReportWithCallback async_get
#define IOHIDDeviceSetReport sync_set
#define IOHIDDeviceGetReport sync_get
#include "native.inc"
int main(int argc,char **argv) {
    assert(argc==2);const char *mode=argv[1];
    HostHIDState *s=calloc(1,sizeof(*s));assert(s);pthread_mutex_init(&s->lock,NULL);
    s->hid=(IOHIDDeviceRef)CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    s->bh=qemu_bh_new(NULL,s);s->live=s->configured=true;s->sizes[0][0]=60;
    s->busy=true;s->transfer_set=strncmp(mode,"get",3)!=0;s->transfer_len=60;
    memset(s->transfer,0x5a,60);entered=dispatch_semaphore_create(0);release_api=dispatch_semaphore_create(0);
    bool overflow=!strcmp(mode,"overflow");
    if(overflow||!strcmp(mode,"malformed")) {
        /* Nobody reads (no hidraw open in the guest): the oldest goes, the device stays. */
        uint8_t report[60];
        for(unsigned i=0;i<(overflow?20:1);i++) { memset(report,i,sizeof(report)); host_hid_receive(s,0,report,overflow?60:59); }
        if(overflow) assert(s->live && s->count==16 && s->dropped==4 &&
                            s->queue[s->head].data[0]==4 && s->queue[(s->head+15)%16].data[0]==19);
        else assert(s->live && s->count==0 && s->dropped==1);
        printf("PASS mode=%s queued=%u dropped=%u live=%d\n",mode,s->count,s->dropped,s->live);
        return 0;
    }
    native_start(s);
    if(!strncmp(mode,"unrealize-",10)) {
        /* Hold the real serial worker; unrealize must retain its state and
         * return before the driver/cancel barrier can complete. */
        teardown=true;main_thread=pthread_self();emit_input=false;
        bool queued=!strcmp(mode,"unrealize-queued");
        hold=!queued;s->transfer_set=!strstr(mode,"get");
        s->product=strdup("fixture");close_ready=dispatch_semaphore_create(0);
        dispatch_suspend(queue);
        assert(native_report(s,s->transfer_set,1,0,s->transfer,60)==USB_RET_ASYNC);
        if(!queued) {
            dispatch_resume(queue);
            assert(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
        }
        /* Bounds a broken synchronous implementation instead of hanging CI. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_global_queue(0,0),^{
            if(queued) dispatch_resume(queue); else dispatch_semaphore_signal(release_api);
        });
        host_hid_unrealize((USBDevice *)s);
        assert(refs==2 && s->hid && s->product && !s->live && s->closing);
        assert(!s->pending && !s->waiting && !s->done);
        assert(dispatch_semaphore_wait(close_ready,DISPATCH_TIME_NOW)!=0);
        assert(!dispatch_semaphore_wait(close_ready,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
        assert(!s->hid && !s->dispatch && !s->cancelled && late_callbacks==1);
        assert(api_calls==(queued?0:1));
        /* Only the QEMU-side callback may drop the retained QOM reference. */
        s->bh->callback(s->bh->opaque);
        assert(refs==1 && !s->bh && !s->product && !s->done);
        dispatch_release(close_ready);
        printf("PASS mode=%s retained-until-drain=1 late-callback=1\n",mode);
        goto cleanup;
    }
    bool close_queued=!strcmp(mode,"close-queued"), close_running=!strcmp(mode,"close-running");
    bool stale=!strcmp(mode,"reset-queued"), removed=!strcmp(mode,"removed-queued");
    input_first=!strcmp(mode,"input-first");if(!strcmp(mode,"capacity-control"))qlimit=2;
    if(!strcmp(mode,"get-short"))length_delta=-1;if(!strcmp(mode,"get-long"))length_delta=1;
    if(strstr(mode,"error")||close_running)api_result=kIOReturnTimeout;
    if(strncmp(mode,"get",3)==0 || strstr(mode,"error") || close_queued || close_running || stale || removed)emit_input=false;
    hold=close_running;dispatch_suspend(queue);
    int r=native_report(s,s->transfer_set,1,0,s->transfer,60);assert(r==USB_RET_ASYNC);
    if(close_queued) {s->closing=true;s->live=false;}
    if(stale)s->epoch++;
    if(removed)s->live=false;
    dispatch_resume(queue);
    if(close_running) {
        assert(!dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
        pthread_mutex_lock(&s->lock);s->closing=true;pthread_mutex_unlock(&s->lock);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(0,0),^{dispatch_semaphore_signal(release_api);});
    }
    if(close_queued||close_running) {
        native_close(s);assert(api_calls==(close_running?1:0));assert(!s->done);assert(!s->hid);
    } else {
        dispatch_sync(queue,^{});dispatch_sync(queue,^{});
        if(stale||removed) {assert(api_calls==0);assert(s->done && s->result==USB_RET_STALL);}
        else if(length_delta||api_result)assert(s->done && s->result==USB_RET_STALL);
        else {
            assert(s->done && s->result==60);
            if(emit_input && input_calls!=1) {
                printf("FAIL input wake lost: mode=%s calls=%u completion=%u input=%u pending=%u native_done=%d result=%d\n",mode,api_calls,completion_calls,input_calls,pending_input,s->done,s->result);
                s->closing=true;native_close(s);return 1;
            }
        }
        s->closing=true;native_close(s);
    }
    printf("PASS mode=%s api=%u sync=%u input=%u pending=%u\n",mode,api_calls,sync_calls,input_calls,pending_input);
cleanup:
    qemu_bh_delete(s->bh);
    dispatch_release(entered);dispatch_release(release_api);pthread_mutex_destroy(&s->lock);free(s);return 0;
}
