// Exposes libdeflate's Huffman code construction so a port can be checked
// against it exactly, rather than by eyeballing compressed sizes.
//
// The functions are `static`, so this includes the whole translation unit to
// reach them. That is the point: it is libdeflate's own code answering, not a
// reimplementation that might have drifted.
//
// Reads from stdin:   <num_syms> <max_codeword_len> <freq>...
// Writes to stdout:   one "<sym> <len> <codeword>" line per symbol with len > 0
#include "../../../../libdeflate/lib/deflate_compress.c"

#include <stdio.h>
#include <stdlib.h>

int main(void) {
	unsigned num_syms, max_len;
	if (scanf("%u %u", &num_syms, &max_len) != 2)
		return 1;

	u32 *freqs = calloc(num_syms, sizeof(u32));
	u8 *lens = calloc(num_syms, sizeof(u8));
	u32 *codewords = calloc(num_syms, sizeof(u32));
	if (!freqs || !lens || !codewords)
		return 1;

	for (unsigned i = 0; i < num_syms; i++)
		if (scanf("%u", &freqs[i]) != 1)
			return 1;

	deflate_make_huffman_code(num_syms, max_len, freqs, lens, codewords);

	for (unsigned i = 0; i < num_syms; i++)
		if (lens[i] != 0)
			printf("%u %u %u\n", i, lens[i], codewords[i]);
	return 0;
}
