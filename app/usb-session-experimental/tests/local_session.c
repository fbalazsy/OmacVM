#include "../activation/activation_flow.h"
#include "../helper/policy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct {double now;int cancel,terms,reaped;} Fake;
static int step(void *p,Stage s){Fake*f=p;if(s==CANCEL)return f->cancel;if(s==EXEC_ACK)return 1;if(s==PAUSE){f->now+=100;if(f->now>3600)f->cancel=1;}if(s==TERM){assert(f->now>3600);f->terms++;f->reaped=1;}return 0;}
static double clk(void*p){return ((Fake*)p)->now;}
static ChildResult wait_child(void*p){return ((Fake*)p)->reaped?(ChildResult){CHILD_REAPED,0,0}:(ChildResult){CHILD_RUNNING,0,0};}
static void frame(Gate*g,unsigned char*p,size_t n){for(size_t i=0;i<n;i++)assert(gate_byte(g,p[i])==(i+1==n?1:0));gate_consume(g);}
int main(void){Fake f={0};Ops o={&f,step,clk,wait_child};assert(activation_flow(&o,0)==0);assert(f.terms==1);Gate g;gate_init(&g);unsigned char hello[80]={0};hello[4]=68;memcpy(hello+12,"test",5);frame(&g,hello,sizeof hello);unsigned char reset[12]={3};frame(&g,reset,sizeof reset);unsigned char output[83]={100};output[4]=71;output[13]=9;output[14]=0x21;output[15]=255;output[17]=2;output[20]=61;memset(output+22,0x5a,61);for(unsigned i=0;i<100000;i++)frame(&g,output,sizeof output);puts("PASS explicit session: simulated 3700s before stop; 100000 HID output61 frames plus hello/reset without lifetime budget");}
