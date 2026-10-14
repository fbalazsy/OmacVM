/* Actual QEMU USB core + exact native wrapper, all IOKit calls shimmed. */
#include "sync-test-base.inc"
static void begin_packet(USBDevice *d, USBPacket *p, bool get, uint8_t *data)
{
    usb_packet_init(p);
    usb_packet_setup(p, get ? USB_TOKEN_IN : USB_TOKEN_OUT,
        usb_ep_get(d, get ? USB_TOKEN_IN : USB_TOKEN_OUT, get ? 0 : 1),0,99,false,false);
    usb_packet_addbuf(p,data,60);
    if(get) p->parameter=UINT64_C(0x003c0000010001a1);
    usb_handle_packet(d,p);
    g_assert_cmpint(p->status,==,USB_RET_ASYNC);
}
int main(void)
{
    const char *mode=getenv("SYNC_CASE");g_assert_nonnull(mode);
    const char *args[]={"sync-core-test","-machine","none","-accel","qtest","-nodefaults","-no-user-config","-display","none","-net","none","-S",NULL};
    char *argv[13];for(int i=0;i<13;i++)argv[i]=g_strdup(args[i]);qemu_init(12,argv);
    USBBus bus;USBPort ports[2];DeviceState *host=qdev_new("usb-hub");
    usb_bus_new(&bus,sizeof(bus),&bops,host);
    for(int i=0;i<2;i++)usb_register_port(&bus,&ports[i],NULL,i,&pops,USB_SPEED_MASK_FULL);
    USBDevice *d=USB_DEVICE(qdev_new("usb-host-hid"));
    qdev_prop_set_uint64(&d->qdev,"registry-id",123);qdev_prop_set_uint16(&d->qdev,"vendorid",0xc251);
    qdev_prop_set_uint16(&d->qdev,"productid",0x1701);qdev_prop_set_string(&d->qdev,"serial","tFIXTUR0E123");
    qdev_realize(&d->qdev,&bus.qbus,&error_abort);usb_device_reset(d);
    int n;g_assert_cmpint(control(d,0x0009,1,0,NULL,0,&n),==,0);
    HostHIDState *s=HOST_HID(d);sync_entered=dispatch_semaphore_create(0);sync_release=dispatch_semaphore_create(0);
    bool get=strstr(mode,"get")!=NULL, cancelled=strstr(mode,"cancel")!=NULL;
    bool reset=strstr(mode,"reset")!=NULL, remove=strstr(mode,"remove")!=NULL;
    bool close_now=strstr(mode,"close")!=NULL, queued=strstr(mode,"queued")!=NULL;
    bool busy=strstr(mode,"busy")!=NULL;
    sync_hold=!queued;sync_length_delta=strstr(mode,"short")?-1:strstr(mode,"long")?1:0;
    sync_result=strstr(mode,"error")?kIOReturnTimeout:0;
    uint8_t data[60];memset(data,0x5a,60);USBPacket p;
    if(queued)dispatch_suspend(shim_queue);
    begin_packet(d,&p,get,data);
    if(!queued)g_assert_cmpint(dispatch_semaphore_wait(sync_entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),==,0);
    g_assert_true(s->busy);g_assert_true(s->pending==&p);
    if(cancelled||close_now)usb_cancel_packet(&p);
    if(reset)usb_device_reset(d);
    if(remove)native_removed(s,0,NULL); /* callback-side terminal state, no BQL */
    USBPacket ctl;uint8_t reply[60]={0};
    if(busy) {begin_packet(d,&ctl,true,reply);g_assert_true(s->waiting==&ctl);}
    if(close_now) {
        if(queued) {
            /* Existing unrealize sets closing before native_close; resume only
             * after that point by observing it under the production mutex. */
            dispatch_async(dispatch_get_global_queue(0,0),^{
                for(;;) {qemu_mutex_lock(&s->lock);bool closing=s->closing;qemu_mutex_unlock(&s->lock);if(closing)break;g_usleep(100);}
                dispatch_resume(shim_queue);
            });
        } else dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(0,0),^{dispatch_semaphore_signal(sync_release);});
        qdev_unrealize(&d->qdev);object_unref(d);
        g_assert_cmpint(review_set_calls+review_get_calls,==,queued?0:1);
    } else {
        if(queued)dispatch_resume(shim_queue);
        else {sync_hold=false;dispatch_semaphore_signal(sync_release);}
        dispatch_sync(shim_queue,^{});main_loop_wait(true);
        if(busy) {
            while(usb_packet_is_inflight(&ctl))main_loop_wait(false);
            g_assert_cmpint(ctl.status,==,0);g_assert_cmpmem(reply,60,s->transfer,60);usb_packet_cleanup(&ctl);
        }
        if(cancelled) {g_assert_false(usb_packet_is_inflight(&p));g_assert_null(s->pending);}
        else if(reset||remove||sync_result||sync_length_delta)g_assert_cmpint(p.status,==,USB_RET_STALL);
        else {g_assert_cmpint(p.status,==,0);g_assert_cmpint(p.actual_length,==,60);if(get)g_assert_cmphex(data[59],==,0xa5);}
        g_assert_false(s->busy);
        if(queued && (reset||remove))g_assert_cmpint(review_set_calls+review_get_calls,==,0);
        qdev_unrealize(&d->qdev);object_unref(d);
    }
    usb_packet_cleanup(&p);dispatch_release(sync_entered);dispatch_release(sync_release);
    printf("PASS actual-core %s set=%d get=%d\n",mode,review_set_calls,review_get_calls);return 0;
}
