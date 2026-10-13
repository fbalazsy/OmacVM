#import "protocol.h"
#include <limits.h>
#include <string.h>
int valid_uuid(const char *s){
 if(!s || strlen(s)!=36)return 0;
 for(unsigned i=0;i<36;i++)if(i==8||i==13||i==18||i==23){if(s[i]!='-')return 0;}else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;
 return 1;
}
/* Deliberately small JSON grammar: objects, unsigned integral numbers, strings.
   Reject duplicate keys, booleans, floats, null, arrays, and excess depth before
   semantic validation. NSJSONSerialization alone silently accepts duplicates. */
typedef struct {const uint8_t *p;size_t n,i;} Reader;
static void ws(Reader *r){while(r->i<r->n && r->p[r->i] && strchr(" \t\r\n",r->p[r->i]))r->i++;}
static id value(Reader *r,unsigned depth){
 if(depth>5)return nil;ws(r);if(r->i>=r->n)return nil;
 if(r->p[r->i]=='"'){
  size_t start=r->i++;int escaped=0;
  while(r->i<r->n){uint8_t c=r->p[r->i++];if(c<32)return nil;
   if(!escaped && c=='"'){
    NSData *d=[NSData dataWithBytes:r->p+start length:r->i-start];
    id s=[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:NULL];
    return [s isKindOfClass:NSString.class] && [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=1024?s:nil;
   }
   if(!escaped && c=='\\')escaped=1;else escaped=0;
  }return nil;
 }
 if(r->p[r->i]=='{'){
  r->i++;ws(r);NSMutableDictionary *d=[NSMutableDictionary dictionary];
  if(r->i<r->n && r->p[r->i]=='}'){r->i++;return d;}
  while(r->i<r->n){
   if(d.count>=16 || r->p[r->i]!='"')return nil;
   id k=value(r,depth+1);if(![k isKindOfClass:NSString.class] || d[k])return nil;
   ws(r);if(r->i>=r->n || r->p[r->i++]!=':')return nil;
   id v=value(r,depth+1);if(!v)return nil;d[k]=v;ws(r);
   if(r->i>=r->n)return nil;uint8_t c=r->p[r->i++];if(c=='}')return d;if(c!=',')return nil;ws(r);
  }return nil;
 }
 size_t start=r->i;while(r->i<r->n && r->p[r->i]>='0' && r->p[r->i]<='9')r->i++;
 size_t n=r->i-start;if(!n||n>20)return nil;char s[21];memcpy(s,r->p+start,n);s[n]=0;
 uint64_t num;if(!scalar(s,UINT64_MAX,&num))return nil;return @(num);
}
static int keys(id d,NSArray *keys){return [d isKindOfClass:NSDictionary.class] && [d count]==keys.count && [[NSSet setWithArray:[d allKeys]] isEqualToSet:[NSSet setWithArray:keys]];}
static int number(id v,uint64_t min,uint64_t max){return [v isKindOfClass:NSNumber.class] && [v unsignedLongLongValue]>=min && [v unsignedLongLongValue]<=max;}
Process request_process(NSDictionary *p){return (Process){[p[@"pid"] intValue],[p[@"uid"] unsignedIntValue],[p[@"start_sec"] unsignedLongLongValue],[p[@"start_usec"] unsignedIntValue],[p[@"version"] unsignedIntValue]};}
NSDictionary *request_parse(NSData *data,NSString *attempt,uid_t uid,int captured){
 if(!data.length || data.length>CONTROL_MAX || !valid_uuid(attempt.UTF8String))return nil;
 Reader r={data.bytes,data.length,0};id d=value(&r,0);ws(&r);
 if(r.i!=r.n || ![d isKindOfClass:NSDictionary.class] || !number(d[@"schema"],1,1) || ![d[@"attempt"] isEqual:attempt])return nil;
 if([d[@"command"] isEqual:@"cancel"])return keys(d,@[@"schema",@"command",@"attempt"])?d:nil;
 if(captured || ![d[@"command"] isEqual:@"capture"] || !keys(d,@[@"schema",@"command",@"attempt",@"device",@"qemu"]))return nil;
 NSDictionary *dev=d[@"device"],*q=d[@"qemu"];
 if(!keys(dev,@[@"registry_id",@"location",@"vendor",@"product",@"serial"]) || !keys(q,@[@"pid",@"uid",@"start_sec",@"start_usec",@"version"]))return nil;
 id s=dev[@"serial"];if(![s isKindOfClass:NSString.class] || ![s lengthOfBytesUsingEncoding:NSUTF8StringEncoding] || [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>SERIAL_MAX || [s rangeOfString:[NSString stringWithCharacters:(unichar[]){0} length:1]].location!=NSNotFound)return nil;
 if(!number(dev[@"registry_id"],1,UINT64_MAX) || !number(dev[@"location"],1,UINT32_MAX) || !number(dev[@"vendor"],1,UINT16_MAX) || !number(dev[@"product"],0,UINT16_MAX) || !number(q[@"pid"],1,INT_MAX) || !number(q[@"uid"],uid,uid) || !number(q[@"start_sec"],1,UINT64_MAX) || !number(q[@"start_usec"],0,999999) || !number(q[@"version"],1,INT_MAX))return nil;
 return d;
}
