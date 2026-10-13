#include "policy.h"
#include <string.h>
int identity_policy(unsigned vid,unsigned pid,unsigned location,unsigned dc,unsigned ds,unsigned dp,unsigned configs,const char *serial,const char *product) {
 return vid==PROFILE_VID && pid==PROFILE_PID && location==PROFILE_LOCATION && !dc && !ds && !dp && configs==1 && serial && product && !strcmp(serial,PROFILE_SERIAL) && !strcmp(product,PROFILE_PRODUCT);
}
int report_policy(const uint8_t *p,size_t n) {
 static const uint8_t report[]=PROFILE_REPORT_BYTES;
 return p && n==sizeof(report) && !memcmp(p,report,n);
}
int config_policy(const uint8_t *p,size_t n) {
 static const uint8_t config[]=PROFILE_CONFIG_BYTES;
 return p && n==sizeof(config) && !memcmp(p,config,n);
}
int invocation(int argc,const char *const *argv,unsigned uid,unsigned euid) {return argc==2 && argv && argv[1] && !strcmp(argv[1],"--serve") && uid==0 && euid==0;}
