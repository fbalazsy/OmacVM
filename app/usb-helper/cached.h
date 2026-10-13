#pragma once
#include "hid.h"
#include <libusb.h>
int cached_device_matches(const uint8_t raw[18],const struct libusb_device_descriptor *device);
int cached_config_matches(const uint8_t *raw,size_t n,const struct libusb_config_descriptor *config);
