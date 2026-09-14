// Exposes libdeflate's precode computation, the run-length encoding that packs
// a dynamic block's codeword lengths into the block header.
//
// Includes libdeflate's translation unit to reach its static functions, so the
// answers come from libdeflate itself rather than a reimplementation.
//
// Reads from stdin:   <num_lens> <len>...
// Writes to stdout:   "items <n>" then one "<item>" line each,
//                     then "freqs" and 19 precode frequencies.
#include "../../../../libdeflate/lib/deflate_compress.c"

#include <stdio.h>
#include <stdlib.h>

int main(void) {
	unsigned num_lens;
	if (scanf("%u", &num_lens) != 1)
		return 1;

	u8 *lens = calloc(num_lens, 1);
	u32 freqs[DEFLATE_NUM_PRECODE_SYMS];
	unsigned *items = calloc(num_lens, sizeof(unsigned));
	if (!lens || !items)
		return 1;

	for (unsigned i = 0; i < num_lens; i++) {
		unsigned v;
		if (scanf("%u", &v) != 1)
			return 1;
		lens[i] = (u8)v;
	}

	unsigned n = deflate_compute_precode_items(lens, num_lens, freqs, items);

	printf("items %u\n", n);
	for (unsigned i = 0; i < n; i++)
		printf("%u\n", items[i]);
	printf("freqs\n");
	for (unsigned i = 0; i < DEFLATE_NUM_PRECODE_SYMS; i++)
		printf("%u\n", freqs[i]);
	return 0;
}
