#include <stdio.h>
#include <string.h>
#include <time.h>

#include "cpucycles.h"
#include "kem.h"
#include "parameters.h"
#include "speed_print.h"

#ifndef NTESTS
#define NTESTS 10000
#endif

#ifndef NWARMUP
#define NWARMUP 10
#endif

uint64_t t[NTESTS];

int main() {

    uint8_t sk[KEM_SECRETKEY_BYTES] = {0};
    uint8_t pk[PUBLICKEY_BYTES] = {0};
    int i = 0;
    clock_t srt, ed;
    clock_t overhead;

    uint8_t ctxt[CIPHERTEXT_BYTES] = {0};
    uint8_t ss1[CRYPTO_BYTES] = {0};
    uint8_t ss2[CRYPTO_BYTES] = {0};

    /* Warm-up is deliberately outside all timed sample arrays. */
    for (i = 0; i < NWARMUP; i++) {
        crypto_kem_keypair(pk, sk);
        crypto_kem_enc(ctxt, ss1, pk);
        if (crypto_kem_dec(ss2, ctxt, sk) != 0 ||
            memcmp(ss1, ss2, CRYPTO_BYTES) != 0) {
            fprintf(stderr, "CORRECTNESS: FAIL\n");
            return 1;
        }
    }
    printf("CORRECTNESS: PASS (%d warm-up KEM transactions)\n", NWARMUP);

    overhead = clock();
    cpucycles();
    overhead = clock() - overhead;

    srt = clock();
    for (i = 0; i < NTESTS; i++) {
        t[i] = cpucycles();
        crypto_kem_keypair(pk, sk);
    }
    ed = clock();
    print_results("keygen_kem: ", t, NTESTS);
    printf("time elapsed: %.8fms\n\n", (double)(ed - srt - overhead * NTESTS) *
                                           1000 / CLOCKS_PER_SEC / NTESTS);

    srt = clock();
    for (i = 0; i < NTESTS; i++) {
        t[i] = cpucycles();
        crypto_kem_enc(ctxt, ss1, pk);
    }
    ed = clock();
    print_results("encap: ", t, NTESTS);
    printf("time elapsed: %.8fms\n\n", (double)(ed - srt - overhead * NTESTS) *
                                           1000 / CLOCKS_PER_SEC / NTESTS);

    srt = clock();
    for (i = 0; i < NTESTS; i++) {
        t[i] = cpucycles();
        crypto_kem_dec(ss2, ctxt, sk);
    }
    ed = clock();
    print_results("decap: ", t, NTESTS);
    printf("time elapsed: %.8fms\n\n", (double)(ed - srt - overhead * NTESTS) *
                                           1000 / CLOCKS_PER_SEC / NTESTS);

    return 0;
}
