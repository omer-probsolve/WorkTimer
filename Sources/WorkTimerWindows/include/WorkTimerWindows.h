#ifndef WORKTIMER_WINDOWS_H
#define WORKTIMER_WINDOWS_H
#include <stdint.h>
#include <stddef.h>
int wt_resolve_lan(const char *hostname, char *ipv4, size_t capacity);
int wt_post(const char *ipv4, uint16_t port, const char *certificate_sha256,
            const uint8_t *body, uint32_t length, uint8_t *response, uint32_t capacity,
            uint32_t *response_length);
void wt_discovery_start(const char *receiver_id);
int wt_discovery_endpoint(char *hostname, size_t capacity, uint16_t *port);
int wt_watch(const char *directory);
int wt_take_changes(void);
int wt_lock(const char *path);
#endif
