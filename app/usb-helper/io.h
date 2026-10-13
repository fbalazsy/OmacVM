#pragma once
#include "process.h"
#include <sys/stat.h>
#include <stddef.h>
#define LINE_MAX_BYTES 16384
typedef struct {char data[LINE_MAX_BYTES+1];size_t used;} Line;
/* 1 line, 0 would-block, -1 EOF/invalid/overflow. Does not read past a newline. */
int line_read(int fd,Line *line);
void line_consume(Line *line);
int nonblocking(int fd);
int send_bounded(int fd,const void *data,size_t n,unsigned milliseconds);
int peer_matches(int fd,const Process *expected);
typedef struct {int fd;dev_t dev;ino_t ino;char path[104];int owned;} SocketOwner;
int socket_create(SocketOwner *s,const char *path,uid_t uid);
int socket_remove(SocketOwner *s);
uint64_t monotonic_ms(void);
