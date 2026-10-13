#include "../cached.h"
#include <assert.h>
#include <stdio.h>
extern int cached_config_matches(const uint8_t *,size_t,const struct libusb_config_descriptor *) __attribute__((weak_import));
extern int cached_device_matches(const uint8_t *,const struct libusb_device_descriptor *) __attribute__((weak_import));
int main(void){assert(cached_config_matches);assert(cached_device_matches);
 uint8_t device[]={18,1,0,2,0,0,0,64,0x34,0x12,0x78,0x56,1,0,1,2,3,1};
 struct libusb_device_descriptor dd={.bLength=18,.bDescriptorType=1,.bcdUSB=0x200,.bMaxPacketSize0=64,.idVendor=0x1234,.idProduct=0x5678,.bcdDevice=1,.iManufacturer=1,.iProduct=2,.iSerialNumber=3,.bNumConfigurations=1};
 assert(cached_device_matches(device,&dd));dd.iSerialNumber=4;assert(!cached_device_matches(device,&dd));dd.iSerialNumber=3;dd.bcdDevice=2;assert(!cached_device_matches(device,&dd));
 uint8_t raw[]={9,2,34,0,1,7,0,0x80,50,9,4,3,0,1,3,0,0,0,9,0x21,0x11,1,0,1,0x22,25,0,7,5,0x85,3,32,0,1};
 struct libusb_endpoint_descriptor ep={.bLength=7,.bDescriptorType=5,.bEndpointAddress=0x85,.bmAttributes=3,.wMaxPacketSize=32,.bInterval=1};
 struct libusb_interface_descriptor alt={.bLength=9,.bDescriptorType=4,.bInterfaceNumber=3,.bNumEndpoints=1,.bInterfaceClass=3,.endpoint=&ep,.extra=raw+18,.extra_length=9};
 struct libusb_interface iface={.altsetting=&alt,.num_altsetting=1};
 struct libusb_config_descriptor c={.bLength=9,.bDescriptorType=2,.wTotalLength=34,.bNumInterfaces=1,.bConfigurationValue=7,.bmAttributes=0x80,.MaxPower=50,.interface=&iface};
 assert(cached_config_matches(raw,sizeof(raw),&c));alt.bInterfaceProtocol=1;assert(!cached_config_matches(raw,sizeof(raw),&c));alt.bInterfaceProtocol=0;
 iface.num_altsetting=2;assert(!cached_config_matches(raw,sizeof(raw),&c));iface.num_altsetting=1;ep.bEndpointAddress=0x81;assert(!cached_config_matches(raw,sizeof(raw),&c));ep.bEndpointAddress=0x85;
 c.extra_length=1;assert(!cached_config_matches(raw,sizeof(raw),&c));puts("cached descriptors PASS: libusb cached topology must equal bounded raw policy, not merely VID/PID");return 0;}
