#pragma once
#include "gate.h"
#include "usbredirhost.h"
typedef struct {int fd,failed;Gate gate;size_t pos;int available;struct usbredirhost *host;} Transport;
int transport_open(Transport *t,int fd,libusb_context *ctx,const HIDPolicy *policy);
int transport_read(Transport *t);
int transport_flush(Transport *t);
void transport_close(Transport *t);
