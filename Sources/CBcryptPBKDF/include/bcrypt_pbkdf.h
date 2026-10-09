#ifndef KEEMAC_BCRYPT_PBKDF_H
#define KEEMAC_BCRYPT_PBKDF_H

#include <stddef.h>
#include <stdint.h>

/// OpenBSD bcrypt_pbkdf, the key derivation of encrypted OpenSSH private keys. Returns 0 on success.
int bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
    uint8_t *key, size_t keylen, unsigned int rounds);

#endif
