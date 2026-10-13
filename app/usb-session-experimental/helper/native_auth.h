#pragma once
#include "policy.h"
int secure_dir(const char *absolute);
int load_manifest(Manifest *m);
int peer_auth(int fd,const Manifest *m);
int executable_protected(void);
