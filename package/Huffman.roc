## Length-limited canonical Huffman code construction, ported from libdeflate's
## `deflate_make_huffman_code` and its helpers.
##
## This follows libdeflate's algorithm closely rather than being rewritten in a
## more obvious style, for two reasons. It has to produce byte-identical output
## -- a code that is merely as good on average still yields a different stream --
## and the shape is what will be optimized later, so a clearer-but-different
## structure would only have to be undone.
##
## In particular the packed representation is kept: symbols and frequencies live
## together in one `U32`, with the symbol in the low `num_symbol_bits` and the
## frequency above it, and a single array serves as input frequencies, then tree
## nodes, then depths, then codewords. That sharing is why the algorithm needs no
## allocation beyond the two output arrays.
Huffman := [].{
	## The lengths and codewords of a constructed code. `lengths` has one entry
	## per symbol, 0 meaning the symbol is unused. `codewords` are bit-reversed,
	## as DEFLATE requires.
	Code : { lengths : List(U8), codewords : List(U32) }

	## Build a length-limited canonical Huffman code for `freqs`.
	##
	## `max_codeword_len` bounds the code length; symbols with zero frequency
	## get length 0. Mirrors `deflate_make_huffman_code`.
	build : List(U32), U64 -> Code
	build = |freqs, max_codeword_len| {
		num_syms = List.len(freqs)
		sorted = Huffman.sort_symbols(freqs)
		num_used = List.len(sorted.symout)

		# A complete Huffman code needs at least two codewords, but a block may
		# use fewer than two symbols -- most often the offset code, which
		# DEFLATE allows to be empty. Some decoders reject that, and every other
		# encoder emits two codewords anyway, so this does too: codeword 0 for
		# symbol 0, codeword 1 for the used symbol if it is not symbol 0, else
		# symbol 1.
		if num_used < 2 {
			sym = if num_used == 1 {
				(List.get(sorted.symout, 0) ?? 0).bitwise_and(Huffman.symbol_mask)
			} else {
				0
			}
			nonzero_idx = if sym != 0 { sym.to_u64() } else { 1 }
			zero_lens = List.repeat(0.U8, num_syms)
			lengths = List.set(zero_lens, 0, 1) ?? zero_lens
			lengths2 = List.set(lengths, nonzero_idx, 1) ?? lengths
			zero_codes = List.repeat(0.U32, num_syms)
			codewords = List.set(zero_codes, nonzero_idx, 1) ?? zero_codes
			{ lengths: lengths2, codewords }
		} else {
			tree = Huffman.build_tree(sorted.symout)
			len_counts = Huffman.compute_length_counts(tree, num_used - 2, max_codeword_len)
			Huffman.gen_codewords(len_counts.nodes, len_counts.counts, max_codeword_len, num_syms)
		}
	}

	num_symbol_bits : U8
	num_symbol_bits = 10

	symbol_mask : U32
	symbol_mask = 1023

	## Sort symbols primarily by frequency and secondarily by symbol value,
	## dropping zero-frequency ones, and pack each as `freq << 10 | sym`.
	##
	## Mirrors `sort_symbols`: a counting sort over one counter per symbol
	## handles the low frequencies, which are the bulk of them, and only the
	## symbols sharing the top counter go through the comparison sort.
	sort_symbols : List(U32) -> { symout : List(U32) }
	sort_symbols = |freqs| {
		num_syms = List.len(freqs)
		num_counters = num_syms
		cap = (num_counters - 1).to_u32_wrap()

		var $counters = List.repeat(0.U32, num_counters)
		var $i = 0.U64
		while $i < num_syms {
			f = List.get(freqs, $i) ?? 0
			slot = f.min(cap).to_u64()
			$counters = List.set($counters, slot, (List.get($counters, slot) ?? 0) + 1) ?? $counters
			$i = $i + 1
		}

		# Make the counters cumulative, skipping the zeroth, which counted the
		# unused symbols. The running total is the number of used symbols.
		var $used = 0.U32
		var $k = 1.U64
		while $k < num_counters {
			count = List.get($counters, $k) ?? 0
			$counters = List.set($counters, $k, $used) ?? $counters
			$used = $used + count
			$k = $k + 1
		}
		num_used = $used.to_u64()

		var $symout = List.repeat(0.U32, num_used)
		var $s = 0.U64
		while $s < num_syms {
			f = List.get(freqs, $s) ?? 0
			if f != 0 {
				slot = f.min(cap).to_u64()
				at = (List.get($counters, slot) ?? 0).to_u64()
				$counters = List.set($counters, slot, (at.to_u32_wrap()) + 1) ?? $counters
				packed = $s.to_u32_wrap().bitwise_or(f.shl_wrap(Huffman.num_symbol_bits))
				$symout = List.set($symout, at, packed) ?? $symout
			} else {
			}
			$s = $s + 1
		}

		# Only the symbols that landed in the top counter still need ordering.
		lo = (List.get($counters, num_counters - 2) ?? 0).to_u64()
		hi = (List.get($counters, num_counters - 1) ?? 0).to_u64()
		{ symout: Huffman.heap_sort_range($symout, lo, hi) }
	}

	## Heapsort `list[lo..hi)` in place, as `heap_sort` does for the tail that
	## the counting sort left unordered.
	heap_sort_range : List(U32), U64, U64 -> List(U32)
	heap_sort_range = |list, lo, hi| {
		length = hi.minus_saturated(lo)
		if length < 2 {
			list
		} else {
			var $a = list
			var $sub = length // 2
			while $sub >= 1 {
				$a = Huffman.heapify_subtree($a, lo, length, $sub)
				$sub = $sub - 1
			}

			var $len = length
			while $len >= 2 {
				last = lo + $len - 1
				root = lo
				tmp = List.get($a, last) ?? 0
				$a = List.set($a, last, List.get($a, root) ?? 0) ?? $a
				$a = List.set($a, root, tmp) ?? $a
				$len = $len - 1
				$a = Huffman.heapify_subtree($a, lo, $len, 1)
			}
			$a
		}
	}

	## Sift `A[subtree_idx]` down. Indices here are 1-based within the range
	## starting at `lo`, matching libdeflate's `A--` trick.
	heapify_subtree : List(U32), U64, U64, U64 -> List(U32)
	heapify_subtree = |list, lo, length, subtree_idx| {
		at = |l, one_based| List.get(l, lo + one_based - 1) ?? 0
		var $a = list
		v = at($a, subtree_idx)
		var $parent = subtree_idx
		var $go = True

		while $go {
			child = $parent * 2
			if child > length {
				$go = False
			} else {
				bigger = if child < length and at($a, child + 1) > at($a, child) {
					child + 1
				} else {
					child
				}
				if v >= at($a, bigger) {
					$go = False
				} else {
					$a = List.set($a, lo + $parent - 1, at($a, bigger)) ?? $a
					$parent = bigger
				}
			}
		}

		List.set($a, lo + $parent - 1, v) ?? $a
	}

	## Build the non-leaf nodes of the Huffman tree in place, as `build_tree`
	## does. Entry `sym_count - 2` ends up the root; every other entry holds its
	## parent index shifted left by `num_symbol_bits`.
	build_tree : List(U32) -> List(U32)
	build_tree = |symout| {
		sym_count = List.len(symout)
		last_idx = sym_count - 1
		freq_of = |l, idx| (List.get(l, idx) ?? 0).bitwise_and(Huffman.symbol_mask.bitwise_not())
		sym_of = |l, idx| (List.get(l, idx) ?? 0).bitwise_and(Huffman.symbol_mask)

		var $a = symout
		var $i = 0.U64
		var $b = 0.U64
		var $e = 0.U64
		var $go = True

		while $go {
			# Take the two lowest-frequency nodes, whether leaves or non-leaves,
			# and make A[e] their parent. Same-type pairs are the common case,
			# so they are tested first.
			new_freq =
				if $i + 1 <= last_idx and ($b == $e or freq_of($a, $i + 1) <= freq_of($a, $b)) {
					f = freq_of($a, $i) + freq_of($a, $i + 1)
					$i = $i + 2
					f
				} else if $b + 2 <= $e and ($i > last_idx or freq_of($a, $b + 1) < freq_of($a, $i)) {
					f = freq_of($a, $b) + freq_of($a, $b + 1)
					$a = List.set($a, $b, $e.to_u32_wrap().shl_wrap(Huffman.num_symbol_bits).bitwise_or(sym_of($a, $b))) ?? $a
					$a = List.set($a, $b + 1, $e.to_u32_wrap().shl_wrap(Huffman.num_symbol_bits).bitwise_or(sym_of($a, $b + 1))) ?? $a
					$b = $b + 2
					f
				} else {
					f = freq_of($a, $i) + freq_of($a, $b)
					$a = List.set($a, $b, $e.to_u32_wrap().shl_wrap(Huffman.num_symbol_bits).bitwise_or(sym_of($a, $b))) ?? $a
					$i = $i + 1
					$b = $b + 1
					f
				}
			$a = List.set($a, $e, new_freq.bitwise_or(sym_of($a, $e))) ?? $a
			$e = $e + 1
			if $e >= last_idx {
				$go = False
			} else {
			}
		}

		$a
	}

	## Walk the tree computing each node's depth, and from that how many
	## codewords get each length. Mirrors `compute_length_counts`, including its
	## approximate handling of the length limit: when a depth would exceed the
	## maximum, the longest length still in use is taken instead.
	compute_length_counts : List(U32), U64, U64 -> { nodes : List(U32), counts : List(U32) }
	compute_length_counts = |nodes, root_idx, max_codeword_len| {
		var $counts = List.repeat(0.U32, max_codeword_len + 2)
		$counts = List.set($counts, 1, 2) ?? $counts

		var $a = nodes
		# The root sits at depth 0.
		$a = List.set($a, root_idx, (List.get($a, root_idx) ?? 0).bitwise_and(Huffman.symbol_mask)) ?? $a

		var $node = root_idx
		while $node >= 1 {
			idx = $node - 1
			entry = List.get($a, idx) ?? 0
			parent = (entry.shr_zf_wrap(Huffman.num_symbol_bits)).to_u64()
			parent_depth = ((List.get($a, parent) ?? 0).shr_zf_wrap(Huffman.num_symbol_bits)).to_u64()
			depth = parent_depth + 1

			# Record the depth so it is available when this node's children are
			# visited; the traversal runs parents-before-children.
			$a = List.set($a, idx, entry.bitwise_and(Huffman.symbol_mask).bitwise_or(depth.to_u32_wrap().shl_wrap(Huffman.num_symbol_bits))) ?? $a

			capped =
				if depth >= max_codeword_len {
					var $d = max_codeword_len
					var $searching = True
					while $searching {
						$d = $d - 1
						if (List.get($counts, $d) ?? 0) != 0 {
							$searching = False
						} else {
						}
					}
					$d
				} else {
					depth
				}

			# One fewer codeword at this depth, two more one level down.
			$counts = List.set($counts, capped, (List.get($counts, capped) ?? 0) - 1) ?? $counts
			$counts = List.set($counts, capped + 1, (List.get($counts, capped + 1) ?? 0) + 2) ?? $counts
			$node = $node - 1
		}

		{ nodes: $a, counts: $counts }
	}

	## Assign lengths to symbols and produce canonical, bit-reversed codewords.
	## Mirrors `gen_codewords`.
	gen_codewords : List(U32), List(U32), U64, U64 -> Code
	gen_codewords = |nodes, len_counts, max_codeword_len, num_syms| {
		# Lengths go to symbols in decreasing order, over symbols already sorted
		# by increasing frequency then increasing value.
		var $lengths = List.repeat(0.U8, num_syms)
		var $i = 0.U64
		var $len = max_codeword_len
		while $len >= 1 {
			var $count = List.get(len_counts, $len) ?? 0
			while $count > 0 {
				sym = ((List.get(nodes, $i) ?? 0).bitwise_and(Huffman.symbol_mask)).to_u64()
				$lengths = List.set($lengths, sym, $len.to_u8_wrap()) ?? $lengths
				$i = $i + 1
				$count = $count - 1
			}
			$len = $len - 1
		}

		# The lexicographically first codeword of each length, then codewords
		# handed out in symbol order, which is what makes the code canonical.
		var $next = List.repeat(0.U32, max_codeword_len + 1)
		var $l = 2.U64
		while $l <= max_codeword_len {
			prev = List.get($next, $l - 1) ?? 0
			cnt = List.get(len_counts, $l - 1) ?? 0
			$next = List.set($next, $l, (prev + cnt).shl_wrap(1)) ?? $next
			$l = $l + 1
		}

		var $codewords = List.repeat(0.U32, num_syms)
		var $s = 0.U64
		while $s < num_syms {
			len = (List.get($lengths, $s) ?? 0).to_u64()
			if len != 0 {
				code = List.get($next, len) ?? 0
				$next = List.set($next, len, code + 1) ?? $next
				$codewords = List.set($codewords, $s, Huffman.reverse_codeword(code, len)) ?? $codewords
			} else {
			}
			$s = $s + 1
		}

		{ lengths: $lengths, codewords: $codewords }
	}

	## DEFLATE stores codewords bit-reversed.
	reverse_codeword : U32, U64 -> U32
	reverse_codeword = |codeword, len| {
		var $out = 0.U32
		var $in = codeword
		var $n = len
		while $n > 0 {
			$out = $out.shl_wrap(1).bitwise_or($in.bitwise_and(1))
			$in = $in.shr_zf_wrap(1)
			$n = $n - 1
		}
		$out
	}
}
