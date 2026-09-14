// Exposes libdeflate's true-cost computation, broken into its parts, so a port
// can be checked against it exactly.
//
// Reads from stdin:  288 litlen freqs, then 32 offset freqs
#include "../../../../libdeflate/lib/deflate_compress.c"
#include <stdio.h>

int main(void) {
	static struct libdeflate_compressor c;
	c.freqs.litlen[0] = 0;
	for (unsigned i = 0; i < DEFLATE_NUM_LITLEN_SYMS; i++)
		if (scanf("%u", &c.freqs.litlen[i]) != 1) return 1;
	for (unsigned i = 0; i < DEFLATE_NUM_OFFSET_SYMS; i++)
		if (scanf("%u", &c.freqs.offset[i]) != 1) return 1;

	deflate_make_huffman_codes(&c.freqs, &c.codes);
	u32 total = deflate_compute_true_cost(&c);

	u32 hdr = 5 + 5 + 4 + (3 * c.o.precode.num_explicit_lens);
	u32 pre = 0;
	for (unsigned s = 0; s < DEFLATE_NUM_PRECODE_SYMS; s++)
		pre += c.o.precode.freqs[s] * (c.o.precode.lens[s] + deflate_extra_precode_bits[s]);

	printf("joined %u:", c.o.precode.num_litlen_syms + c.o.precode.num_offset_syms);
	{ unsigned k; u8 *L = (u8 *)&c.codes.lens;
	  for (k = 0; k < c.o.precode.num_litlen_syms; k++) printf(" %u", L[k]);
	  for (k = 0; k < c.o.precode.num_offset_syms; k++) printf(" %u", c.codes.lens.offset[k]); }
	printf("\n");
	printf("precode_freqs:");
	for (unsigned s = 0; s < DEFLATE_NUM_PRECODE_SYMS; s++) printf(" %u", c.o.precode.freqs[s]);
	printf("\nprecode_lens:");
	for (unsigned s = 0; s < DEFLATE_NUM_PRECODE_SYMS; s++) printf(" %u", c.o.precode.lens[s]);
	printf("\n");
	printf("total=%u num_litlen=%u num_offset=%u num_explicit=%u fixed=%u precode=%u num_items=%u\n",
	       total, c.o.precode.num_litlen_syms, c.o.precode.num_offset_syms,
	       c.o.precode.num_explicit_lens, hdr, pre, c.o.precode.num_items);
	return 0;
}
