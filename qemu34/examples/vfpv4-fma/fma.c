#include <stdio.h>
#include <stdlib.h>
int main(int c, char **v){ volatile double a=1.5,b=2.0,d=0.25; double r;
 __asm__ volatile("vfma.f64 %P0, %P1, %P2" : "=w"(r) : "w"(a), "w"(b), "0"(d));
 printf("VFPV4-FMA %s (r=%g)\n", r==3.25?"OK":"WRONG", r); return r==3.25?0:1; }
