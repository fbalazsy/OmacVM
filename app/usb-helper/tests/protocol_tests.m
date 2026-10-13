#import <Foundation/Foundation.h>
#include <stdio.h>
/* Weak imports let the pre-implementation test report an actual missing feature. */
extern NSDictionary *request_parse(NSData *,NSString *,uid_t,int) __attribute__((weak_import));
extern int valid_uuid(const char *) __attribute__((weak_import));
#define CHECK(x) do {if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;}count++;}while(0)
int main(void){@autoreleasepool {unsigned count=0;
 CHECK(request_parse && valid_uuid);
 NSString *u=@"01234567-89ab-cdef-0123-456789abcdef";
 CHECK(valid_uuid(u.UTF8String));CHECK(!valid_uuid("01234567-89AB-cdef-0123-456789abcdef"));
 NSString *capture=[NSString stringWithFormat:@"{\"schema\":1,\"command\":\"capture\",\"attempt\":\"%@\",\"device\":{\"registry_id\":18446744073709551615,\"location\":123,\"vendor\":1,\"product\":2,\"serial\":\"raw \\u00e9\"},\"qemu\":{\"pid\":42,\"uid\":501,\"start_sec\":12,\"start_usec\":45,\"version\":1}}",u];
 CHECK(request_parse([capture dataUsingEncoding:NSUTF8StringEncoding],u,501,0));
 NSString *spaced=[@"\t\r\n " stringByAppendingString:capture];
 CHECK(request_parse([spaced dataUsingEncoding:NSUTF8StringEncoding],u,501,0));
 for(NSString *bad in @[
 [capture stringByReplacingOccurrencesOfString:@"\"schema\":1" withString:@"\"schema\":true"],
 [capture stringByReplacingOccurrencesOfString:@"\"schema\":1" withString:@"\"schema\":1.0"],
 [capture stringByReplacingOccurrencesOfString:@"\"schema\":1" withString:@"\"schema\":1,\"schema\":1"],
 [capture stringByReplacingOccurrencesOfString:@"18446744073709551615" withString:@"18446744073709551616"],
 [capture stringByReplacingOccurrencesOfString:@"\"uid\":501" withString:@"\"uid\":502"],
 [capture stringByReplacingOccurrencesOfString:@"\"vendor\":1" withString:@"\"vendor\":65536"],
 [capture stringByReplacingOccurrencesOfString:@"\"version\":1" withString:@"\"version\":0"],
 [capture stringByAppendingString:@"{}"],
 [capture stringByReplacingOccurrencesOfString:@"raw \\u00e9" withString:@"a\\u0000b"],
 [capture stringByReplacingOccurrencesOfString:@"\"command\":\"capture\"" withString:@"\"command\":\"exec\""]
 ])CHECK(!request_parse([bad dataUsingEncoding:NSUTF8StringEncoding],u,501,0));
 NSMutableData *nul=[[capture dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];[nul appendBytes:"\0" length:1];CHECK(!request_parse(nul,u,501,0));
 CHECK(!request_parse([capture dataUsingEncoding:NSUTF8StringEncoding],u,501,1));
 NSString *cancel=[NSString stringWithFormat:@"{\"schema\":1,\"command\":\"cancel\",\"attempt\":\"%@\"}",u];
 CHECK(request_parse([cancel dataUsingEncoding:NSUTF8StringEncoding],u,501,1));
 CHECK(request_parse([cancel dataUsingEncoding:NSUTF8StringEncoding],u,501,0));
 printf("protocol: %u assertions PASS\n",count);return 0;
}}
