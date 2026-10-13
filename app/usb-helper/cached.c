#include "cached.h"
#include <string.h>
static unsigned le16(const uint8_t *p){return p[0]|((unsigned)p[1]<<8);}
int cached_device_matches(const uint8_t p[18],const struct libusb_device_descriptor *d){
 return p&&d&&d->bLength==p[0]&&d->bDescriptorType==p[1]&&d->bcdUSB==le16(p+2)&&d->bDeviceClass==p[4]&&d->bDeviceSubClass==p[5]&&d->bDeviceProtocol==p[6]&&d->bMaxPacketSize0==p[7]&&d->idVendor==le16(p+8)&&d->idProduct==le16(p+10)&&d->bcdDevice==le16(p+12)&&d->iManufacturer==p[14]&&d->iProduct==p[15]&&d->iSerialNumber==p[16]&&d->bNumConfigurations==p[17];
}
int cached_config_matches(const uint8_t *p,size_t n,const struct libusb_config_descriptor *c){
 HIDPolicy policy={0};if(!hid_config(p,n,&policy)||!c||c->bLength!=p[0]||c->bDescriptorType!=p[1]||c->wTotalLength!=n||c->bNumInterfaces!=1||c->bConfigurationValue!=p[5]||c->iConfiguration!=p[6]||c->bmAttributes!=p[7]||c->MaxPower!=p[8]||c->extra_length||!c->interface||c->interface[0].num_altsetting!=1||!c->interface[0].altsetting)return 0;
 const struct libusb_interface_descriptor *i=c->interface[0].altsetting;const uint8_t *r=p+9;
 if(i->bLength!=r[0]||i->bDescriptorType!=r[1]||i->bInterfaceNumber!=r[2]||i->bAlternateSetting||i->bNumEndpoints!=r[4]||i->bInterfaceClass!=3||i->bInterfaceSubClass||i->bInterfaceProtocol||i->iInterface!=r[8]||i->extra_length!=9||!i->extra||memcmp(i->extra,p+18,9)||!i->endpoint)return 0;
 for(unsigned a=0;a<i->bNumEndpoints;a++){const struct libusb_endpoint_descriptor *e=i->endpoint+a;const uint8_t *raw=p+27+7*a;
  if(e->bLength!=7||e->bDescriptorType!=5||e->bEndpointAddress!=raw[2]||e->bmAttributes!=3||e->wMaxPacketSize!=le16(raw+4)||e->bInterval!=raw[6]||e->extra_length)return 0;
 }return 1;
}
