#pragma once
#include "hid.h"
#define FRAME_MAX 4128u
typedef struct {uint8_t data[FRAME_MAX];size_t used,need,header;unsigned hello,failed;HIDPolicy policy;} Gate;
void gate_init(Gate *g,const HIDPolicy *policy);
int gate_byte(Gate *g,uint8_t b);
void gate_consume(Gate *g);
