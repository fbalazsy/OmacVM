#pragma once
#include <stdint.h>
#include <stddef.h>
#include "../activation/local_pins.h"
#define FRAME_MAX 4112u

#define FIXED_DIR "/Library/PrivilegedHelperTools/org.omacvm.usb-session-experimental/run"
#define FIXED_SOCKET FIXED_DIR "/usb.sock"
#define MANIFEST_DIR "/Library/PrivilegedHelperTools/org.omacvm.usb-session-experimental"
#define MANIFEST_FILE "peer.conf"
typedef struct { uint32_t pid, usec, lease, version; uint64_t sec, deadline_ns; unsigned char cdhash[20],device[18],config[34]; } Manifest;
int invocation(int argc, const char *const *argv, unsigned uid, unsigned euid);
int manifest_parse(const char *s, size_t n, Manifest *out);
int protected_node(unsigned uid, unsigned mode, unsigned links, int directory, int immutable);
int peer_policy(const Manifest *m, unsigned uid, unsigned euid, unsigned pid, uint64_t sec, unsigned usec, const unsigned char hash[20]);
int report_policy(const uint8_t *p, size_t n);
int config_policy(const uint8_t *p, size_t n);
int identity_policy(unsigned vid,unsigned pid,unsigned location,unsigned dc,unsigned ds,unsigned dp,unsigned configs,const char *serial,const char *product);
typedef struct { uint8_t data[FRAME_MAX]; size_t used, need, header; unsigned hello, count, failed; } Gate;
void gate_init(Gate *g);
/* Feed exactly one byte. 1=complete validated frame; 0=more; -1=fatal. */
int gate_byte(Gate *g, uint8_t b);
void gate_consume(Gate *g);
int lease_live(double now, double started, unsigned seconds, int stopped);
