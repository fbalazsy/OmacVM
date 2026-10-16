/* Same-process integration: actual handlers, full ordinary/native units and
 * real QEMU QOM/USB/BH/dispatch. Only IOKit/libusb calls are shimmed. */
static const uint8_t descriptor[]={0x06,0x00,0xff,0x09,0x01,0xa1,0x01,0x15,0x00,0x26,0xff,0x00,0x75,0x08,0x95,0x3c,0x09,0x01,0x81,0x02,0x95,0x3c,0x09,0x01,0x91,0x02,0x95,0x01,0x09,0x01,0xb1,0x02,0xc0};
static QDict *command(const char*name,QDict*args,const char*failure)
{
 char *full=g_strconcat("x-omacvm-usb-coexistence-",name,NULL);
 QmpCommand*cmd=qmp_find_command(&qmp_commands,full);g_free(full);
 assert(cmd);QObject*ret=NULL;Error*err=NULL;cmd->fn(args,&ret,&err);qobject_unref(args);
 if(failure) {assert(err && !ret && g_str_has_prefix(error_get_pretty(err),failure));error_free(err);return NULL;}
 if(err)fprintf(stderr,"COMMAND %s: %s\n",name,error_get_pretty(err));
 assert(!err && ret);return qobject_to(QDict,ret);
}
static QDict *prepare_input(uint64_t session)
{
 QDict*d=qdict_new(),*owner=qdict_new(),*t=qdict_new();
 qdict_put_str(owner,"launch","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");qdict_put(owner,"task",coex_read_task(getppid()));
 coex_put(t,"root-id",11+(session-55)*10);coex_put(t,"interface-id",22+(session-55)*10);coex_put(t,"hid-id",33+(session-55)*10);
 qdict_put_int(t,"vendor-id",0xc251);qdict_put_int(t,"product-id",0x1701);qdict_put_str(t,"serial-utf8","tFIXTUR0E123");
 char*h=g_compute_checksum_for_data(G_CHECKSUM_SHA256,descriptor,sizeof(descriptor));qdict_put_str(t,"descriptor-sha256",h);g_free(h);
 qdict_put(d,"launcher",owner);qdict_put(d,"target",t);coex_put(d,"sequence",1);return d;
}
static QDict *mutator(uint64_t seq)
{
 QDict*d=qdict_new(),*call=qdict_new();qdict_put(call,"lease",qobject_ref(coex_lease));coex_put(call,"sequence",seq);qdict_put(d,"call",call);return d;
}
static QDict *commit_input(uint64_t seq,unsigned cycle)
{
 QDict*d=mutator(seq);qdict_put(d,"published",qobject_ref(coex_published));coex_put(d,"guard-client-id",66);
 qdict_put(d,"guard-task",coex_read_task(getppid()));qdict_put_str(d,"guard-open","nonseizing-success");
 char id[64];snprintf(id,sizeof(id),"cycle-native-%u",cycle);qdict_put_str(d,"device-id",id);return d;
}
static QDict *revoke_input(uint64_t seq)
{QDict*d=mutator(seq);qdict_put_str(d,"reason","user");return d;}
static QDict *release_input(uint64_t seq,uint64_t guard)
{QDict*d=mutator(seq);coex_put(d,"guard-client-id",guard);qdict_put_bool(d,"guard-closed",true);return d;}
static QDict *guard_gone_input(uint64_t seq)
{QDict*d=release_input(seq,66);qdict_put_bool(d,"guard-closed",false);qdict_put_bool(d,"guard-disposed-gone",true);return d;}
static QDict *query_input(void)
{QDict*d=qdict_new();qdict_put(d,"lease",qobject_ref(coex_lease));return d;}
static void wait_state(const char*state)
{
 int64_t end=g_get_monotonic_time()+2000000;
 while(strcmp(coex_state,state)) {assert(g_get_monotonic_time()<end);main_loop_wait(true);g_usleep(1000);}
}
static USBHostDevice *ordinary_new(USBBus*bus,int address)
{
 USBHostDevice*s=USB_HOST_DEVICE(qdev_new("usb-host"));
 qdev_prop_set_uint32(DEVICE(s),"hostbus",0);qdev_prop_set_uint32(DEVICE(s),"hostaddr",address);
 qdev_realize(DEVICE(s),BUS(bus),&error_abort);assert(s->dh);usb_device_reset(USB_DEVICE(s));s->options=0;
 USBPacket p={0};usb_host_set_config(s,1,&p);assert(p.status==USB_RET_SUCCESS);return s;
}
static void ordinary_drop(USBHostDevice*s)
{qdev_unrealize(DEVICE(s));object_unparent(OBJECT(s));object_unref(s);}
static void bulk_read(USBHostDevice*s)
{
 uint8_t data[60]={0};USBPacket p;USBDevice*d=USB_DEVICE(s);
 usb_packet_init(&p);usb_packet_setup(&p,USB_TOKEN_IN,usb_ep_get(d,USB_TOKEN_IN,1),0,100,false,false);usb_packet_addbuf(&p,data,sizeof(data));
 usb_handle_packet(d,&p);assert(p.status==USB_RET_ASYNC);
 struct timeval tv={0};libusb_handle_events_timeout(ctx,&tv);
 assert(!usb_packet_is_inflight(&p) && p.status==0 && p.actual_length==60 && data[0]==0xa5);
 usb_packet_cleanup(&p);
}
static void native_begin(USBPacket *p,uint8_t *data)
{
 USBDevice*d=fixture_native_device();assert(d);usb_device_reset(d);
 USBPacket cfg={0};USBDeviceClass*dc=USB_DEVICE_GET_CLASS(d);
 dc->handle_control(d,&cfg,0x0009,1,0,0,NULL);assert(cfg.status==0);
 usb_packet_init(p);
 usb_packet_setup(p,USB_TOKEN_IN,usb_ep_get(d,USB_TOKEN_IN,0),0,100,false,false);usb_packet_addbuf(p,data,60);
 p->parameter=UINT64_C(0x003c0000010001a1);usb_handle_packet(d,p);assert(p->status==USB_RET_ASYNC);
}
static void native_read(void)
{
 uint8_t data[60]={0};USBPacket p;native_begin(&p,data);
 int64_t end=g_get_monotonic_time()+2000000;
 while(usb_packet_is_inflight(&p)) {assert(g_get_monotonic_time()<end);main_loop_wait(false);}
 assert(p.status==0 && p.actual_length==60 && data[0]==0xa5);usb_packet_cleanup(&p);
}
static void heartbeat(void*opaque) {*(bool*)opaque=true;}
static void integrated_cycle(USBBus*bus,const char*mode)
{
 fixture_native_init();
 bool prepared_first=!strcmp(mode,"native-first");
 if(prepared_first) {
  fixture_graph(55,false,false);QDict*r=command("prepare",prepare_input(55),NULL);qobject_unref(r);
  assert(init_calls==1 && !devices[0].opens && !devices[1].opens);
 }
 USBHostDevice*b=ordinary_new(bus,2);bulk_read(b);
 unsigned b_opens=devices[1].opens;
 for(unsigned i=0;i<2;i++) {
  uint64_t session=i?58:55;devices[0].id=session;
  fixture_graph(session,false,false);
  QDict*r=prepared_first && !i ? command("status",query_input(),NULL) : command("prepare",prepare_input(session),NULL);
  assert(!strcmp(qdict_get_str(r,"state"),"guard-pending"));qobject_unref(r);
  fixture_graph(session,true,false);
  /* Real registry tree contains the guard before the next QMP transaction. */
  coex_watchdog(NULL);
  assert(!strcmp(coex_state,"guard-pending") && !coex_ticket && !coex_native);
  if(!strcmp(mode,"native-open-failure"))fixture_native_failure(true,false);
  if(!strcmp(mode,"native-create-failure"))fixture_native_create_failure();
  if(!strcmp(mode,"native-close-failure"))fixture_native_failure(false,true);
  bool postfail=g_str_has_prefix(mode,"native-postopen-");
  bool postclose=!strcmp(mode,"native-postopen-close-failure");
  bool identityfail=!strcmp(mode,"native-create-identity");
  if(postfail)fixture_postopen_failure(!strcmp(mode,"native-postopen-extra")?2:1,postclose);
  if(identityfail)fixture_identity_failure();
  USBPacket held;uint8_t held_data[60]={0};
  const char *failure=!strcmp(mode,"native-open-failure")?"failed to open":!strcmp(mode,"native-create-failure")?"not a vendor HID":NULL;
  if(postfail)failure="COEX_POLICY";
  if(identityfail)failure="HID identity";
  r=command("commit",commit_input(2,i),failure);
  if(r) {
   assert(!strcmp(qdict_get_str(r,"state"),"native"));qobject_unref(r);
   if(!strcmp(mode,"native-held") || !strcmp(mode,"native-gone-held")) {
    fixture_native_hold(true);native_begin(&held,held_data);held_native_packet=&held;fixture_native_wait();
   } else {native_read();}
  }
  bulk_read(b);assert(devices[1].opens==b_opens && devices[1].closes==0);
  if(failure) {
   if(postclose) {
    wait_state("uncertain");assert(!coex_ticket->closed && !coex_native && fixture_native_device());
    command("release",release_input(3,66),"COEX_UNCERTAIN");ordinary_drop(b);return;
   }
   int o,c,reports;wait_state("guard-release");fixture_native_counts(&o,&c,&reports);
   assert(!reports && o==(postfail?1:0) && c==(postfail?1:0) && !coex_native);
   if(postfail){
    assert(!fixture_native_device());fixture_graph(session,false,false);
    command("release",release_input(3,66),"COEX_UNCERTAIN");ordinary_drop(b);return;
   }
   wait_state("guard-release");fixture_graph(session,false,false);
   r=command("release",release_input(3,66),NULL);qobject_unref(r);
   assert(!fixture_native_device());ordinary_drop(b);puts("PASS actual-core failed native Create/Open -> real close boundary -> guard-release -> retirement");return;
  }
  if(!strcmp(mode,"native-foreign")) {fixture_foreign();coex_watchdog(NULL);assert(!coex_active());}
  bool gone=g_str_has_prefix(mode,"native-gone");
  bool goneheld=!strcmp(mode,"native-gone-held");
  bool guardgone=g_str_has_prefix(mode,"guard-gone") || !strcmp(mode,"native-gone-guard-disposed");
  bool gonefail=gone && strcmp(mode,"native-gone") && !goneheld && !guardgone;
  unsigned loss_mode=!strcmp(mode,"native-gone-unknown")?1:
    !strcmp(mode,"native-gone-invalid")?2:!strcmp(mode,"native-gone-root")?3:
    !strcmp(mode,"native-gone-guard")?4:!strcmp(mode,"native-gone-native")?5:
    !strcmp(mode,"native-gone-postrelease")?6:!strcmp(mode,"native-gone-race")?7:
    !strcmp(mode,"native-gone-live-error")?8:!strcmp(mode,"native-gone-bql-proof")?9:0;
  if(gone)fixture_loss_mode(loss_mode);
  if(gone)fixture_graph(session,true,true);
  if(loss_mode==8)fixture_graph(session,true,false);
  if(!strcmp(mode,"native-gone-stale")) {
   pthread_mutex_lock(&session_lock);session_find(session)->epoch++;pthread_mutex_unlock(&session_lock);
  }
  if(!strcmp(mode,"native-gone-no-native")) {
   pthread_mutex_lock(&session_lock);coex_ticket->native=0;pthread_mutex_unlock(&session_lock);
  }
  if(!strcmp(mode,"native-gone-pending")) {
   pthread_mutex_lock(&session_lock);session_find(session)->callbacks++;pthread_mutex_unlock(&session_lock);
  }
  r=command("revoke",revoke_input(3),NULL);qobject_unref(r);
  if(!strcmp(mode,"native-held") || goneheld) {
   assert(!strcmp(coex_state,"revoking") && !coex_ticket->closed);
   command("release",release_input(4,66),"COEX_UNCERTAIN");
   bool observed=false;QEMUBH*bh=qemu_bh_new(heartbeat,&observed);qemu_bh_schedule(bh);
   while(!observed)main_loop_wait(false);
   qemu_bh_delete(bh);bulk_read(b);
   assert(!coex_ticket->closed && !usb_host_session_acquire(&devices[0]));
   if(goneheld) {unsigned r,s,c;fixture_disposal_counts(&r,&s,&c);assert(!r && !c);}
   fixture_native_hold(false);
  }
  if(gonefail) {
   wait_state("uncertain");assert(!coex_ticket->closed && fixture_native_device());
   command("release",release_input(4,66),"COEX_UNCERTAIN");
   unsigned released,scans,attempts;fixture_disposal_counts(&released,&scans,&attempts);
   assert(released==((loss_mode==6 || loss_mode==9)?1:0) && attempts==1);
   assert(!usb_host_session_acquire(&devices[0]));bulk_read(b);ordinary_drop(b);
   puts("PASS actual-core gone-proof negative: no ACK, old freeze/quarantine retained, B continues");return;
  }
  if(!strcmp(mode,"native-close-failure")) {
   wait_state("uncertain");command("release",release_input(4,66),"COEX_UNCERTAIN");
   assert(!usb_host_session_acquire(&devices[0]));bulk_read(b);ordinary_drop(b);
   puts("PASS actual-core native close failure stays uncertain; B continues");return;
  }
  wait_state("guard-release");assert(!fixture_native_device());
  if(guardgone) {
   assert(coex_ticket->closed && coex_ticket->disposal==(gone?COEX_DISPOSAL_OLD_GENERATION_GONE:COEX_DISPOSAL_CHECKED_CLOSE));
   unsigned fault=!strcmp(mode,"guard-gone-unknown")?1:!strcmp(mode,"guard-gone-invalid")?2:
       !strcmp(mode,"guard-gone-root")?3:!strcmp(mode,"guard-gone-guard")?4:!strcmp(mode,"guard-gone-native")?5:0;
   bool live=!strcmp(mode,"guard-gone-live");
   fixture_graph(session,false,!live);fixture_loss_mode(fault);
   if(fault || live) {
    command("release",guard_gone_input(4),"COEX_UNCERTAIN");
    assert(coex_sequence==3 && !strcmp(coex_state,"guard-release") && session_find(session)->frozen && session_find(session)->dev);
    /* Live tree can be clean, but this disposal must never fall back to it.
     * Unknown proof can retry proof-only against the same immutable old IDs. */
    fixture_graph(session,false,true);fixture_loss_mode(0);
   }
   r=command("release",guard_gone_input(4),NULL);qobject_unref(r);
   assert(!strcmp(coex_state,"retired") && session_find(session)->frozen && !session_find(session)->dev);
   assert(!usb_host_session_acquire(&devices[0]));
   r=command("status",query_input(),NULL);assert(coex_sequence==4);qobject_unref(r);
   unsigned released,scans,attempts;fixture_disposal_counts(&released,&scans,&attempts);
   assert(released==1 && attempts==1);bulk_read(b);ordinary_drop(b);
   puts("PASS actual-core guard disposal: independent full exact-ID scan, terminal-only; native drain/release once; status recovery");return;
  }
  if(gone) {
   if(goneheld){assert(!usb_packet_is_inflight(&held));usb_packet_cleanup(&held);held_native_packet=NULL;}
   unsigned released,scans,attempts;fixture_disposal_counts(&released,&scans,&attempts);
   int o,c,reports;fixture_native_counts(&o,&c,&reports);
   assert(released==1 && scans>=3 && attempts==1 && o==1 && c==0);
   assert(coex_ticket->disposal==COEX_DISPOSAL_OLD_GENERATION_GONE);
   r=command("release",release_input(4,66),NULL);
   assert(!strcmp(qdict_get_str(r,"state"),"retired"));qobject_unref(r);
   assert(session_find(session)->frozen && !session_find(session)->dev);
   bulk_read(b);ordinary_drop(b);
   puts("PASS actual-core physical loss: Close BadArgument, executed CFRelease, post-release exact-ID absence, frozen old retirement (NOT Close0)");return;
  }
  assert(coex_ticket->disposal==COEX_DISPOSAL_CHECKED_CLOSE);
  if(!strcmp(mode,"native-held")) {
   assert(!usb_packet_is_inflight(&held));usb_packet_cleanup(&held);held_native_packet=NULL;
  }
  fixture_graph(session,false,true);r=command("release",release_input(4,66),NULL);
  assert(!strcmp(qdict_get_str(r,"state"),"retired"));qobject_unref(r);
  assert(session_find(session)->frozen && !session_find(session)->dev);
  if(!strcmp(mode,"native-foreign")) {
   bulk_read(b);ordinary_drop(b);puts("PASS actual-core post-adoption foreign client strict watchdog -> actual native close; B continues");return;
  }
  if(!strcmp(mode,"native-held")) {
   ordinary_drop(b);puts("PASS actual-core held native GET -> async revoke; independent BH and B traffic; real worker/callback/close ACK");return;
  }
  if(!i) {
   devices[0].id=57;
   USBHostDevice*a=ordinary_new(bus,1);bulk_read(a);bulk_read(b);ordinary_drop(a);
   assert(devices[0].closes==1);
  }
 }
 int opened,closed,reports;fixture_native_counts(&opened,&closed,&reports);
 assert(opened==2 && closed==2 && reports==2 && init_calls==1);
 assert(devices[1].opens==b_opens && !devices[1].closes);
 ordinary_drop(b);
 assert(devices[1].refs==0); /* Idle never-leased ordinary sessions reclaim refs. */
 printf("PASS actual-core HID(read)->bulk(read)->HID(read) same PID=%d init=1 native-open=2 native-close=2 B-opens=1 B-reads=%d\n",getpid(),devices[1].submits);
}
