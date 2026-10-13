#include "../activation/activation_policy.h"
#include "../activation/continuous_clock.h"
#include <assert.h>
#include <stdio.h>
int main(void){Request r;char b[513];assert(request_parse("12345","10","1","0",&r));assert(manifest_format(&r,b,sizeof b));assert(deadline_valid(9000000000000,0,0));assert(!deadline_valid(900,1,0));puts("PASS session manifest and zero deadline");}
