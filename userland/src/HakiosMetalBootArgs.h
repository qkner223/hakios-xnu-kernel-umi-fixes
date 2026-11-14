#ifndef HAKIOS_METAL_BOOT_ARGS_H
#define HAKIOS_METAL_BOOT_ARGS_H

#include <string.h>

/* A complete boot-argument token, including its value when supplied. */
static inline int
hm_boot_arg_token(const char *arguments, const char *wanted)
{
	const size_t length = strlen(wanted);
	for (const char *p = arguments; *p;) {
		p += strspn(p, " \t\r\n");
		const size_t n = strcspn(p, " \t\r\n");
		if (n != 0 && n == length && memcmp(p, wanted, n) == 0) return 1;
		p += n;
	}
	return 0;
}

#endif
