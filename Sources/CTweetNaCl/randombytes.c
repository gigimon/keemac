#include <stdlib.h>

void randombytes(unsigned char *buffer, unsigned long long length) {
    arc4random_buf(buffer, (size_t)length);
}
