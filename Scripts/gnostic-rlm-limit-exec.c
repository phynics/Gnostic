#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

static int parse_limit(const char *argument, const char *prefix, rlim_t *value) {
    size_t prefix_length = strlen(prefix);
    if (strncmp(argument, prefix, prefix_length) != 0) {
        return 0;
    }

    const char *digits = argument + prefix_length;
    if (*digits == '\0' || *digits == '-') {
        return -1;
    }

    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(digits, &end, 10);
    if (errno != 0 || end == digits || *end != '\0' || parsed == 0 || parsed > (unsigned long long) RLIM_INFINITY) {
        return -1;
    }

    *value = (rlim_t) parsed;
    return 1;
}

static int apply_limit(int resource, rlim_t requested, const char *name) {
    struct rlimit current;
    if (getrlimit(resource, &current) != 0) {
        perror("gnostic-rlm-limit-exec: getrlimit");
        return -1;
    }

    if (current.rlim_cur > requested || current.rlim_max > requested) {
        struct rlimit bounded = { .rlim_cur = requested, .rlim_max = requested };
        if (setrlimit(resource, &bounded) != 0) {
            fprintf(stderr, "gnostic-rlm-limit-exec: cannot apply %s limit: %s\n", name, strerror(errno));
            return -1;
        }
    }

    if (getrlimit(resource, &current) != 0) {
        perror("gnostic-rlm-limit-exec: verify getrlimit");
        return -1;
    }
    if (current.rlim_cur > requested || current.rlim_max > requested) {
        fprintf(stderr, "gnostic-rlm-limit-exec: %s limit is not bounded to %llu\n", name, (unsigned long long) requested);
        return -1;
    }
    return 0;
}

static void usage(void) {
    fputs("usage: gnostic-rlm-limit-exec --cpu=SECONDS [--as=BYTES] -- PROGRAM [ARG ...]\n", stderr);
}

int main(int argc, char **argv) {
    rlim_t cpu_limit = 0;
    rlim_t address_space_limit = 0;
    int has_cpu_limit = 0;
    int has_address_space_limit = 0;
    int separator = -1;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--") == 0) {
            separator = index;
            break;
        }

        int parsed = parse_limit(argv[index], "--cpu=", &cpu_limit);
        if (parsed == 1) {
            if (has_cpu_limit) {
                usage();
                return 64;
            }
            has_cpu_limit = 1;
            continue;
        }
        if (parsed == -1) {
            usage();
            return 64;
        }

        parsed = parse_limit(argv[index], "--as=", &address_space_limit);
        if (parsed == 1) {
            if (has_address_space_limit) {
                usage();
                return 64;
            }
            has_address_space_limit = 1;
            continue;
        }
        usage();
        return 64;
    }

    if (!has_cpu_limit || separator < 0 || separator + 1 >= argc) {
        usage();
        return 64;
    }

    if (apply_limit(RLIMIT_CPU, cpu_limit, "CPU") != 0) {
        return 125;
    }

    if (has_address_space_limit) {
#if defined(__linux__) && defined(RLIMIT_AS)
        if (apply_limit(RLIMIT_AS, address_space_limit, "address-space") != 0) {
            return 125;
        }
#else
        fputs("gnostic-rlm-limit-exec: address-space limit is unsupported on this platform\n", stderr);
        return 125;
#endif
    }

    execvp(argv[separator + 1], &argv[separator + 1]);
    int execution_error = errno;
    fprintf(stderr, "gnostic-rlm-limit-exec: cannot execute %s: %s\n", argv[separator + 1], strerror(execution_error));
    return execution_error == ENOENT ? 127 : 126;
}
