/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * husk-android: on-device pairing is not built (no Rust, no StikJIT). JIT comes
 * from a host running huskjit-net instead, so every entry point here reports
 * that pairing is unavailable and HuskRPPairing.h's callers fail cleanly.
 */
#include <stdlib.h>
#include <string.h>

#include "HuskRPPairing.h"

HuskRPPairing *husk_rppairing_new(const char *name, char **error)
{
    (void)name;
    if (error) *error = strdup("On-device pairing is not part of this build; JIT comes from huskjit-net.");
    return NULL;
}

uint16_t husk_rppairing_port(const HuskRPPairing *session) { (void)session; return 0; }
const char *husk_rppairing_service_name(const HuskRPPairing *session) { (void)session; return ""; }
size_t husk_rppairing_txt_count(const HuskRPPairing *session) { (void)session; return 0; }
const char *husk_rppairing_txt_key(const HuskRPPairing *session, size_t index) { (void)session; (void)index; return NULL; }
const char *husk_rppairing_txt_value(const HuskRPPairing *session, size_t index) { (void)session; (void)index; return NULL; }

int32_t husk_rppairing_accept(const HuskRPPairing *session,
                              HuskRPPairingPinCallback pin_callback, void *pin_context,
                              uint8_t **out_plist, size_t *out_len,
                              char **out_device_name, char **error)
{
    (void)session; (void)pin_callback; (void)pin_context;
    if (out_plist) *out_plist = NULL;
    if (out_len) *out_len = 0;
    if (out_device_name) *out_device_name = NULL;
    if (error) *error = strdup("On-device pairing is not part of this build.");
    return 1;
}

void husk_rppairing_cancel(const HuskRPPairing *session) { (void)session; }
void husk_rppairing_free(HuskRPPairing *session) { (void)session; }
void husk_rppairing_bytes_free(uint8_t *bytes, size_t len) { (void)len; free(bytes); }
void husk_rppairing_string_free(char *string) { free(string); }
