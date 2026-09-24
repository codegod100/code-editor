#include <stdio.h>
#include <string.h>
#include "Smoke.h"
int main(void) {
  uint8_t buf[] = "freeq";
  Smoke_xor_bytes(buf, 5, 0, 0x20);
  for (int i = 0; i < 5; i++) printf("%c", buf[i]);
  printf("\n");
  Smoke_xor_bytes(buf, 5, 0, 0x20);   /* involutive: back again */
  for (int i = 0; i < 5; i++) printf("%c", buf[i]);
  printf("\n");
  return 0;
}
