## The precode: the run-length encoding that packs a dynamic block's codeword
## lengths into its header.
##
## A dynamic block has to describe its own Huffman codes, which means sending
## 288 + 32 codeword lengths. Sending them raw would cost more than the codes
## save, so DEFLATE compresses them with a third Huffman code -- the precode --
## over an alphabet of the lengths 0-15 plus three run-length symbols:
##
##   16: repeat the previous length 3-6 more times
##   17: a run of 3-10 zeroes
##   18: a run of 11-138 zeroes
##
## Ported from libdeflate's `deflate_compute_precode_items`, keeping its
## structure so the item stream matches exactly; a different but equally valid
## encoding of the same lengths would still change the output bytes.
Precode := [].{
	## An RLE item: the precode symbol in the low 5 bits, its extra bits above.
	Items : { items : List(U32), freqs : List(U32) }

	## Number of symbols in the precode alphabet.
	num_syms : U64
	num_syms = 19

	## Maximum precode codeword length.
	max_codeword_len : U64
	max_codeword_len = 7

	## The order precode lengths are written in. Lengths likely to be zero come
	## last, so trailing zeroes can be dropped from the header.
	lens_permutation : List(U8)
	lens_permutation = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

	## Run-length encode `lens` into precode items, and count how often each
	## precode symbol is used. Mirrors `deflate_compute_precode_items`.
	compute_items : List(U8) -> Items
	compute_items = |lens| {
		num_lens = List.len(lens)
		var $freqs = List.repeat(0.U32, Precode.num_syms)
		var $items = List.with_capacity(num_lens)
		var $run_start = 0.U64

		while $run_start < num_lens {
			len = List.get(lens, $run_start) ?? 0

			# Extend the run of equal lengths.
			var $run_end = $run_start + 1
			while $run_end != num_lens and len == (List.get(lens, $run_end) ?? 0) {
				$run_end = $run_end + 1
			}

			if len == 0 {
				# Symbol 18 covers 11 to 138 zeroes at a time.
				while ($run_end - $run_start) >= 11 {
					extra = (($run_end - $run_start) - 11).min(127)
					$freqs = Precode.bump($freqs, 18)
					$items = List.append($items, 18 + extra.to_u32_wrap().shl_wrap(5))
					$run_start = $run_start + 11 + extra
				}

				# Symbol 17 covers 3 to 10.
				if ($run_end - $run_start) >= 3 {
					extra = (($run_end - $run_start) - 3).min(7)
					$freqs = Precode.bump($freqs, 17)
					$items = List.append($items, 17 + extra.to_u32_wrap().shl_wrap(5))
					$run_start = $run_start + 3 + extra
				} else {
				}
			} else {
				# Symbol 16 repeats the previous length 3 to 6 more times, so a
				# run is only worth encoding once there are at least 4 of them:
				# one written out, then the rest repeated.
				if ($run_end - $run_start) >= 4 {
					$freqs = Precode.bump($freqs, len.to_u64())
					$items = List.append($items, len.to_u32())
					$run_start = $run_start + 1
					var $more = True
					while $more {
						extra = (($run_end - $run_start) - 3).min(3)
						$freqs = Precode.bump($freqs, 16)
						$items = List.append($items, 16 + extra.to_u32_wrap().shl_wrap(5))
						$run_start = $run_start + 3 + extra
						if ($run_end - $run_start) < 3 {
							$more = False
						} else {
						}
					}
				} else {
				}
			}

			# Whatever the run-length symbols did not cover goes out literally.
			while $run_start != $run_end {
				$freqs = Precode.bump($freqs, len.to_u64())
				$items = List.append($items, len.to_u32())
				$run_start = $run_start + 1
			}
		}

		{ items: $items, freqs: $freqs }
	}

	bump : List(U32), U64 -> List(U32)
	bump = |freqs, idx|
		List.set(freqs, idx, (List.get(freqs, idx) ?? 0) + 1) ?? freqs

	## How many litlen codeword lengths must be sent: everything up to the last
	## one in use, but never fewer than 257. Mirrors the trimming loop in
	## `deflate_precompute_huffman_header`.
	num_litlen_syms : List(U8) -> U64
	num_litlen_syms = |litlen_lens| {
		var $n = 288.U64
		var $searching = True
		while $searching and $n > 257 {
			if (List.get(litlen_lens, $n - 1) ?? 0) != 0 {
				$searching = False
			} else {
				$n = $n - 1
			}
		}
		$n
	}

	## How many offset codeword lengths must be sent, never fewer than 1.
	num_offset_syms : List(U8) -> U64
	num_offset_syms = |offset_lens| {
		var $n = 32.U64
		var $searching = True
		while $searching and $n > 1 {
			if (List.get(offset_lens, $n - 1) ?? 0) != 0 {
				$searching = False
			} else {
				$n = $n - 1
			}
		}
		$n
	}

	## How many of the 19 precode lengths must be written, in permutation order.
	## Trailing zeroes are dropped, but at least 4 are always sent.
	num_explicit_lens : List(U8) -> U64
	num_explicit_lens = |precode_lens| {
		var $n = Precode.num_syms
		var $searching = True
		while $searching and $n > 4 {
			at = (List.get(Precode.lens_permutation, $n - 1) ?? 0).to_u64()
			if (List.get(precode_lens, at) ?? 0) != 0 {
				$searching = False
			} else {
				$n = $n - 1
			}
		}
		$n
	}
}
