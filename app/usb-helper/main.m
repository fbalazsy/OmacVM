#import <Foundation/Foundation.h>
#include "process.h"
#include "protocol.h"
#include "security.h"
#include "session.h"
#include "supervisor.h"
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
static void stop_signal(int s){interrupted=s;}
int main(int argc,const char *argv[]){@autoreleasepool {
 if(argc==3 && !strcmp(argv[1],"--inspect-process")){
  uint64_t pid;Process p;
  if(!scalar(argv[2],INT_MAX,&pid)||!process_read((pid_t)pid,&p))return 65;
  printf("{\"schema\":1,\"pid\":%d,\"uid\":%u,\"start_sec\":%llu,\"start_usec\":%u,\"version\":%u}\n",p.pid,p.uid,(unsigned long long)p.sec,p.usec,p.version);return 0;
 }
 if(argc==8 && (!strcmp(argv[1],"--session")||!strcmp(argv[1],"--worker"))){
  uint64_t uid,pid,sec,usec,version;
  if(!valid_uuid(argv[2])||!scalar(argv[3],UINT32_MAX-1,&uid)||!uid||!scalar(argv[4],INT_MAX,&pid)||!pid||!scalar(argv[5],UINT64_MAX,&sec)||!sec||!scalar(argv[6],999999,&usec)||!scalar(argv[7],INT_MAX,&version)||!version)return 64;
  if(getuid()!=0||geteuid()!=0)return 77;
  char self[4096];if(!self_protected(self))return 65;
  struct rlimit core={0,0};if(setrlimit(RLIMIT_CORE,&core))return 65;umask(077);
  struct sigaction sa={0};sigemptyset(&sa.sa_mask);sa.sa_handler=stop_signal;
  if(sigaction(SIGTERM,&sa,NULL)||sigaction(SIGINT,&sa,NULL)||sigaction(SIGHUP,&sa,NULL))return 65;
  int worker=!strcmp(argv[1],"--worker");Process identity={(pid_t)pid,worker?0:(uid_t)uid,sec,(uint32_t)usec,(uint32_t)version};
  return worker?worker_main(argv[2],(uid_t)uid,&identity):session_main(argv[2],(uid_t)uid,&identity,self);
 }
 return 64;
}}
