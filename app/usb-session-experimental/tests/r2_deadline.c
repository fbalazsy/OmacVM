/* Producer must not restart helper's relative lease clock. */
#include "../activation/activation_policy.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
int main(void){Request r={.pid=123,.sec=456,.lease=5,.version=7,.deadline_ns=9000000000};char text[513];assert(manifest_format(&r,text,sizeof text));assert(strstr(text,"\ndeadline_ns="));puts("PASS absolute deadline serialized");}
