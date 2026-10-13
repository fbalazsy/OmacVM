#pragma once
#include <stdint.h>
#include <stddef.h>
#define REPORT_MAX 4096
#define CONFIG_MAX 64
typedef struct {uint8_t configuration,interface,in_ep,out_ep;uint16_t in_max,out_max,report_length;uint16_t bytes[3];} HIDPolicy;
int hid_report(const uint8_t *p,size_t n,HIDPolicy *out);
int hid_config(const uint8_t *p,size_t n,HIDPolicy *out);
