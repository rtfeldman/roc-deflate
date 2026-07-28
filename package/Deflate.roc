import CompressFastest
import CompressSmallest

## DEFLATE (RFC 1951) compression and decompression in pure Roc.
##
## `decompress` handles all three block types (stored, fixed Huffman, dynamic
## Huffman), so it can read streams produced by zlib, gzip, and ZIP tools.
## `compress` picks its strategy from the level it is given: `Fastest` runs a
## hash-table matchfinder in a single greedy pass, `Smallest` searches a binary
## tree and finds the cheapest path through the matches under a cost model it
## refines over several passes, and `Balanced` uses hash-chain LZ77 with lazy
## matching. All three produce streams any inflate implementation can read.

## Errors that can occur when decompressing a DEFLATE stream.
DeflateError : [
	CorruptData,
	UnexpectedEnd,
]

## How hard [Deflate.compress] searches for LZ77 matches, trading speed for
## size: `Fastest` gives up quickly, `Smallest` searches far deeper, and
## `Balanced` sits in between (roughly zlib's default effort).
Level : [Fastest, Balanced, Smallest]

Deflate := [].{

	## Compress bytes into a raw DEFLATE stream.
	compress : List(U8), Level -> List(U8)
	compress = |input, level| match level {
		Fastest => CompressFastest.compress(input)
		Smallest => CompressSmallest.compress(input)
		Balanced => Deflate.compress_balanced(input)
	}

	compress_balanced : List(U8) -> List(U8)
	compress_balanced = |input| {
		# Match-search tuning in the spirit of zlib's configuration table:
		# chain candidates to try per position, the deferred-match length that
		# skips the lazy search, and the match length that stops a search early.
		{ max_chain, max_lazy, nice_match } = { max_chain: 32, max_lazy: 16, nice_match: 128 }
		# Read the module-level tables once and precompute packed emit codes:
		# in the interpreter, every access to a top-level list constant
		# re-materializes the list, so hot paths must not touch them.
		# This is a Roc compiler bug which will certainly be resolved soon.
		len_codes = build_length_codes(length_bases, length_extra_bits, 0, List.with_capacity(256))
		dist_codes = build_dist_codes(dist_extra_bits, 0, List.with_capacity(32768))
		table = List.repeat(0, hash_size + window_size)
		out = List.with_capacity(input.len().shr_wrap(1) + 8)

		# Block header: bfinal = 1, btype = 01 (fixed Huffman). Three bits,
		# packed least significant first: 1, then 1, 0
		compress_loop(input, 0, table, out, 3, 3, Bool.False, 0, 0, len_codes, dist_codes, max_chain, max_lazy, nice_match)
	}

	## Decompress a raw DEFLATE stream.
	decompress : List(U8) -> Try(List(U8), DeflateError)
	decompress = |input| {
		# Top-level table lists are read once here and threaded through (see the note in compress)
		inflate_blocks(input, 0, [], length_bases, length_extra_bits, dist_bases, dist_extra_bits)
	}
}

# --- Shared tables (RFC 1951 section 3.2.5) ---

# Length symbols 257-285, indexed 0-28
length_bases : List(U16)
length_bases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]

length_extra_bits : List(U8)
length_extra_bits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

# Distance symbols 0-29
dist_bases : List(U32)
dist_bases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]

dist_extra_bits : List(U8)
dist_extra_bits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

# Order in which code-length code lengths are stored in a dynamic block
code_length_order : List(U64)
code_length_order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

max_code_length : U16
max_code_length = 15

end_of_block_symbol : U16
end_of_block_symbol = 256

# --- Inflate ---
#
# Performance note for this whole module: lists are only ever passed as bare
# function arguments and threaded through tail recursion. Wrapping a list in
# a record that's returned per step (or accumulated in a fold) currently
# defeats in-place mutation and turns linear algorithms quadratic.
# Re-evaluate this in a later Roc compiler version.

# Read `count` bits starting at bit `offset` (LSB-first, per RFC 1951).
read_bits : List(U8), U64, U8 -> Try({ value : U32, next : U64 }, DeflateError)
read_bits = |bytes, offset, count|
	read_bits_help(bytes, offset, count, 0, 0)

read_bits_help : List(U8), U64, U8, U8, U32 -> Try({ value : U32, next : U64 }, DeflateError)
read_bits_help = |bytes, offset, remaining, shift, acc|
	if remaining == 0 {
		Ok({ value: acc, next: offset })
	} else {
		byte = bytes.get(offset.shr_wrap(3)) ? |_| UnexpectedEnd
		bit = byte.shr_wrap(offset.bitwise_and(7).to_u8_wrap()).bitwise_and(1).to_u32()
		read_bits_help(bytes, offset + 1, remaining - 1, shift + 1, acc + bit.shl_wrap(shift))
	}

inflate_blocks : List(U8), U64, List(U8), List(U16), List(U8), List(U32), List(U8) -> Try(List(U8), DeflateError)
inflate_blocks = |input, offset, out, len_bases, len_extras, d_bases, d_extras| {
	{ value: bfinal, next: after_final } = read_bits(input, offset, 1)?
	{ value: btype, next: after_type } = read_bits(input, after_final, 2)?

	result = 
		if btype == 0 {
			inflate_stored(input, after_type, out)?
		} else if btype == 1 {
			lit_counts = huffman_counts(fixed_literal_lengths({}))
			lit_symbols = huffman_symbols(fixed_literal_lengths({}))
			dist_counts = huffman_counts(fixed_distance_lengths({}))
			dist_symbols = huffman_symbols(fixed_distance_lengths({}))
			inflate_huffman(input, after_type, out, lit_counts, lit_symbols, dist_counts, dist_symbols, len_bases, len_extras, d_bases, d_extras)?
		} else if btype == 2 {
			tables = read_dynamic_tables(input, after_type)?
			lit_counts = huffman_counts(tables.lit_lengths)
			lit_symbols = huffman_symbols(tables.lit_lengths)
			dist_counts = huffman_counts(tables.dist_lengths)
			dist_symbols = huffman_symbols(tables.dist_lengths)
			inflate_huffman(input, tables.next, out, lit_counts, lit_symbols, dist_counts, dist_symbols, len_bases, len_extras, d_bases, d_extras)?
		} else {
			return Err(CorruptData)
		}

	if bfinal == 1 {
		Ok(result.out)
	} else {
		inflate_blocks(input, result.next, result.out, len_bases, len_extras, d_bases, d_extras)
	}
}

# A stored block: skip to the next byte boundary, then LEN, its one's
# complement NLEN, and LEN raw bytes.
inflate_stored : List(U8), U64, List(U8) -> Try({ out : List(U8), next : U64 }, DeflateError)
inflate_stored = |input, offset, out| {
	header_start = offset.shr_wrap(3) + (
		if offset.bitwise_and(7) == 0 {
			0
		} else {
			1
		},
	)
	len_lo = input.get(header_start) ? |_| UnexpectedEnd
	len_hi = input.get(header_start + 1) ? |_| UnexpectedEnd
	nlen_lo = input.get(header_start + 2) ? |_| UnexpectedEnd
	nlen_hi = input.get(header_start + 3) ? |_| UnexpectedEnd
	len = len_lo.to_u64() + len_hi.to_u64().shl_wrap(8)
	nlen = nlen_lo.to_u64() + nlen_hi.to_u64().shl_wrap(8)
	if len + nlen != 0xFFFF {
		Err(CorruptData)
	} else {
		data = input.sublist({ start: header_start + 4, len })
		if data.len() != len {
			Err(UnexpectedEnd)
		} else {
			appended = data.fold(out, |acc, byte| acc.append(byte))
			Ok({ out: appended, next: (header_start + 4 + len).shl_wrap(3) })
		}
	}
}

# Decode literal/length and distance symbols until the end-of-block symbol.
inflate_huffman : List(U8), U64, List(U8), List(U16), List(U16), List(U16), List(U16), List(U16), List(U8), List(U32), List(U8) -> Try({ out : List(U8), next : U64 }, DeflateError)
inflate_huffman = |input, offset, out, lit_counts, lit_symbols, dist_counts, dist_symbols, len_bases, len_extras, d_bases, d_extras| {
	{ symbol, next } = decode_symbol(input, offset, lit_counts, lit_symbols)?
	if symbol < end_of_block_symbol {
		inflate_huffman(input, next, out.append(symbol.to_u8_wrap()), lit_counts, lit_symbols, dist_counts, dist_symbols, len_bases, len_extras, d_bases, d_extras)
	} else if symbol == end_of_block_symbol {
		Ok({ out, next })
	} else if symbol > 285 {
		Err(CorruptData)
	} else {
		length_index = (symbol - 257).to_u64()
		length_base = (len_bases.get(length_index) ?? 0).to_u64()
		length_extra = len_extras.get(length_index) ?? 0
		{ value: length_add, next: after_length } = read_bits(input, next, length_extra)?
		length = length_base + length_add.to_u64()

		{ symbol: dist_symbol, next: after_dist_symbol } = decode_symbol(input, after_length, dist_counts, dist_symbols)?
		if dist_symbol > 29 {
			Err(CorruptData)
		} else {
			dist_base = (d_bases.get(dist_symbol.to_u64()) ?? 0).to_u64()
			dist_extra = d_extras.get(dist_symbol.to_u64()) ?? 0
			{ value: dist_add, next: after_dist } = read_bits(input, after_dist_symbol, dist_extra)?
			distance = dist_base + dist_add.to_u64()

			if distance > out.len() {
				Err(CorruptData)
			} else {
				copied = copy_match(out, distance, length)
				inflate_huffman(input, after_dist, copied, lit_counts, lit_symbols, dist_counts, dist_symbols, len_bases, len_extras, d_bases, d_extras)
			}
		}
	}
}

# Copy `length` bytes starting `distance` bytes back in the output. Copies
# byte-by-byte because the ranges may overlap (that's how DEFLATE encodes
# runs).
copy_match : List(U8), U64, U64 -> List(U8)
copy_match = |out, distance, length|
	if length == 0 {
		out
	} else {
		byte = out.get(out.len() - distance) ?? 0
		copy_match(out.append(byte), distance, length - 1)
	}

# Decode one symbol by walking code lengths shortest-first, tracking the
# first canonical code and symbol index of each length.
decode_symbol : List(U8), U64, List(U16), List(U16) -> Try({ symbol : U16, next : U64 }, DeflateError)
decode_symbol = |bytes, offset, counts, symbols|
	decode_symbol_help(bytes, offset, counts, symbols, 1, 0, 0, 0)

decode_symbol_help : List(U8), U64, List(U16), List(U16), U16, U32, U32, U64 -> Try({ symbol : U16, next : U64 }, DeflateError)
decode_symbol_help = |bytes, offset, counts, symbols, len, code, first, index|
	if len > max_code_length {
		Err(CorruptData)
	} else {
		byte = bytes.get(offset.shr_wrap(3)) ? |_| UnexpectedEnd
		bit = byte.shr_wrap(offset.bitwise_and(7).to_u8_wrap()).bitwise_and(1).to_u32()
		# Huffman codes accumulate MSB-first
		next_code = code * 2 + bit
		count = (counts.get(len.to_u64()) ?? 0).to_u32()
		if next_code < first + count {
			symbol = symbols.get(index + (next_code - first).to_u64()) ? |_| CorruptData
			Ok({ symbol, next: offset + 1 })
		} else {
			decode_symbol_help(bytes, offset + 1, counts, symbols, len + 1, next_code, (first + count) * 2, index + count.to_u64())
		}
	}

# How many codes exist of each length, indexed by length (0-15).
huffman_counts : List(U8) -> List(U16)
huffman_counts = |lengths|
	lengths.fold(
		List.repeat(0, 16),
		|acc, len|
			if len == 0 {
				acc
			} else {
				current = acc.get(len.to_u64()) ?? 0
				match acc.set(len.to_u64(), current + 1) {
					Ok(updated) => updated
					Err(_) => []
				}
			},
	)

# Symbols sorted by (code length, symbol value), the canonical Huffman order.
huffman_symbols : List(U8) -> List(U16)
huffman_symbols = |lengths| {
	indexed = lengths.map_with_index(|len, index| { len, symbol: index.to_u16_wrap() })
	collect_symbols_of_length(indexed, 1, [])
}

collect_symbols_of_length : List({ len : U8, symbol : U16 }), U16, List(U16) -> List(U16)
collect_symbols_of_length = |indexed, len, acc|
	if len > max_code_length {
		acc
	} else {
		next = indexed.fold(
			acc,
			|a, entry|
				if entry.len.to_u16() == len {
					a.append(entry.symbol)
				} else {
					a
				},
		)
		collect_symbols_of_length(indexed, len + 1, next)
	}

fixed_literal_lengths : {} -> List(U8)
fixed_literal_lengths = |{}|
	List.repeat(8, 144)
		.concat(List.repeat(9, 112))
		.concat(List.repeat(7, 24))
		.concat(List.repeat(8, 8))

fixed_distance_lengths : {} -> List(U8)
fixed_distance_lengths = |{}|
	List.repeat(5, 32)

# Read the code-length declarations of a dynamic Huffman block (RFC 1951
# section 3.2.7) and return the literal/length and distance code lengths.
read_dynamic_tables : List(U8), U64 -> Try({ lit_lengths : List(U8), dist_lengths : List(U8), next : U64 }, DeflateError)
read_dynamic_tables = |input, offset| {
	{ value: hlit, next: after_hlit } = read_bits(input, offset, 5)?
	{ value: hdist, next: after_hdist } = read_bits(input, after_hlit, 5)?
	{ value: hclen, next: after_hclen } = read_bits(input, after_hdist, 4)?
	lit_count = hlit.to_u64() + 257
	dist_count = hdist.to_u64() + 1
	code_length_count = hclen.to_u64() + 4

	if lit_count > 286 or dist_count > 30 {
		Err(CorruptData)
	} else {
		{ lengths: cl_lengths, next: after_cl } = read_code_length_lengths(input, after_hclen, 0, code_length_count, List.repeat(0, 19), code_length_order)?
		cl_counts = huffman_counts(cl_lengths)
		cl_symbols = huffman_symbols(cl_lengths)

		{ lengths: all_lengths, next } = decode_code_lengths(input, after_cl, cl_counts, cl_symbols, lit_count + dist_count, [])?
		Ok({
			lit_lengths: all_lengths.sublist({ start: 0, len: lit_count }),
			dist_lengths: all_lengths.sublist({ start: lit_count, len: dist_count }),
			next,
		})
	}
}

# The code-length code lengths are 3 bits each, stored in a fixed
# permutation order.
read_code_length_lengths : List(U8), U64, U64, U64, List(U8), List(U64) -> Try({ lengths : List(U8), next : U64 }, DeflateError)
read_code_length_lengths = |input, offset, index, count, lengths, order|
	if index == count {
		Ok({ lengths, next: offset })
	} else {
		{ value, next } = read_bits(input, offset, 3)?
		position = order.get(index) ?? 0
		updated = 
			match lengths.set(position, value.to_u8_wrap()) {
				Ok(l) => l
				Err(_) => []
			}
		read_code_length_lengths(input, next, index + 1, count, updated, order)
	}

# Decode the literal/length and distance code lengths as one sequence, with
# run-length symbols: 16 repeats the previous length, 17 and 18 emit zeros.
decode_code_lengths : List(U8), U64, List(U16), List(U16), U64, List(U8) -> Try({ lengths : List(U8), next : U64 }, DeflateError)
decode_code_lengths = |input, offset, cl_counts, cl_symbols, target, acc|
	if acc.len() >= target {
		if acc.len() == target {
			Ok({ lengths: acc, next: offset })
		} else {
			Err(CorruptData)
		}
	} else {
		{ symbol, next } = decode_symbol(input, offset, cl_counts, cl_symbols)?
		if symbol <= 15 {
			decode_code_lengths(input, next, cl_counts, cl_symbols, target, acc.append(symbol.to_u8_wrap()))
		} else if symbol == 16 {
			previous = acc.last() ? |_| CorruptData
			{ value, next: after_extra } = read_bits(input, next, 2)?
			decode_code_lengths(input, after_extra, cl_counts, cl_symbols, target, append_repeated(acc, previous, value.to_u64() + 3))
		} else if symbol == 17 {
			{ value, next: after_extra } = read_bits(input, next, 3)?
			decode_code_lengths(input, after_extra, cl_counts, cl_symbols, target, append_repeated(acc, 0, value.to_u64() + 3))
		} else if symbol == 18 {
			{ value, next: after_extra } = read_bits(input, next, 7)?
			decode_code_lengths(input, after_extra, cl_counts, cl_symbols, target, append_repeated(acc, 0, value.to_u64() + 11))
		} else {
			Err(CorruptData)
		}
	}

append_repeated : List(U8), U8, U64 -> List(U8)
append_repeated = |list, value, count|
	if count == 0 {
		list
	} else {
		append_repeated(list.append(value), value, count - 1)
	}

# --- Compress ---
#
# The writer keeps pending bits in an accumulator and flushes complete
# bytes into the output list. Emit helpers return scalar-only records. The
# output list and hash table are only ever passed and returned bare (see the
# performance note above), so both are mutated in place throughout.

hash_size : U64
hash_size = 32768

window_size : U64
window_size = 32768

min_match : U64
min_match = 3

max_match : U64
max_match = 258

# A minimal-length match this far back costs more bits than three literals.
too_far : U64
too_far = 4096

# Reverse the low `count` bits of `code`. DEFLATE packs Huffman codes most
# significant bit first, opposite to everything else. Pre-reversing them lets
# the writer append every field least significant bit first.
reverse_bits : U32, U8 -> U32
reverse_bits = |code, count|
	reverse_bits_help(code, count, 0)

reverse_bits_help : U32, U8, U32 -> U32
reverse_bits_help = |code, remaining, acc|
	if remaining == 0 {
		acc
	} else {
		reverse_bits_help(code.shr_wrap(1), remaining - 1, acc.shl_wrap(1).bitwise_or(code.bitwise_and(1)))
	}

# The bits encoding one literal byte.
literal_bits : U8 -> { value : U64, count : U8 }
literal_bits = |byte| {
	code = fixed_literal_code(byte.to_u16())
	{ value: reverse_bits(code.code, code.len).to_u64(), count: code.len }
}

# Packed emit tables, built once per compress call: each entry holds the
# ready-to-append bits (code pre-reversed, extra bits included) in the low
# 32 bits and the bit count above them. Indexed by length - 3 / distance - 1.

build_length_codes : List(U16), List(U8), U64, List(U64) -> List(U64)
build_length_codes = |bases, extras, symbol, acc|
	if symbol > 27 {
		# 258 has its own symbol (28), overriding symbol 27's nominal range
		code = fixed_literal_code(285)
		acc.append(pack_emit(reverse_bits(code.code, code.len).to_u64(), code.len))
	} else {
		base = (bases.get(symbol) ?? 0).to_u64()
		extra = extras.get(symbol) ?? 0
		code = fixed_literal_code(257 + symbol.to_u16_wrap())
		code_rev = reverse_bits(code.code, code.len).to_u64()
		filled = append_length_run(acc, code_rev, code.len, extra, base, 0)
		build_length_codes(bases, extras, symbol + 1, filled)
	}

append_length_run : List(U64), U64, U8, U8, U64, U64 -> List(U64)
append_length_run = |acc, code_rev, code_len, extra, base, offset|
	if offset.shr_wrap(extra) > 0 or base + offset > 257 {
		acc
	} else {
		value = code_rev.bitwise_or(offset.shl_wrap(code_len))
		append_length_run(acc.append(pack_emit(value, code_len + extra)), code_rev, code_len, extra, base, offset + 1)
	}

# Distance bases are contiguous (each base is the previous base plus its
# extra-bit range), so appending every symbol's range in order indexes the
# table by distance - 1 directly.
build_dist_codes : List(U8), U64, List(U64) -> List(U64)
build_dist_codes = |extras, symbol, acc|
	if symbol > 29 {
		acc
	} else {
		extra = extras.get(symbol) ?? 0
		code_rev = reverse_bits(symbol.to_u32_wrap(), 5).to_u64()
		filled = append_dist_run(acc, code_rev, extra, 0)
		build_dist_codes(extras, symbol + 1, filled)
	}

append_dist_run : List(U64), U64, U8, U64 -> List(U64)
append_dist_run = |acc, code_rev, extra, offset|
	if offset.shr_wrap(extra) > 0 {
		acc
	} else {
		value = code_rev.bitwise_or(offset.shl_wrap(5))
		append_dist_run(acc.append(pack_emit(value, 5 + extra)), code_rev, extra, offset + 1)
	}

pack_emit : U64, U8 -> U64
pack_emit = |value, count|
	value.bitwise_or(count.to_u64().shl_wrap(32))

# The bits encoding one match: length code with extra bits, then distance
# code with extra bits, both from the packed tables.
match_bits : U64, U64, List(U64), List(U64) -> { value : U64, count : U8 }
match_bits = |length, distance, len_codes, dist_codes| {
	length_packed = len_codes.get(length - min_match) ?? 0
	dist_packed = dist_codes.get(distance - 1) ?? 0
	length_count = length_packed.shr_wrap(32).to_u8_wrap()
	dist_value = dist_packed.bitwise_and(0xFFFFFFFF)
	dist_count = dist_packed.shr_wrap(32).to_u8_wrap()
	value = length_packed.bitwise_and(0xFFFFFFFF).bitwise_or(dist_value.shl_wrap(length_count))
	{ value, count: length_count + dist_count }
}

# Append every complete byte in the accumulator to the output. The caller
# recomputes the leftover accumulator and bit count arithmetically, so the
# list can be returned bare.
flush_bytes : List(U8), U64, U8 -> List(U8)
flush_bytes = |out, acc, total|
	if total < 8 {
		out
	} else {
		flush_bytes(out.append(acc.bitwise_and(0xFF).to_u8_wrap()), acc.shr_wrap(8), total - 8)
	}

# Emit the end-of-block symbol (a seven-bit all-zero code) and pad the final
# partial byte with zeros.
finish_stream : List(U8), U64, U8 -> List(U8)
finish_stream = |out, acc, nbits| {
	total = nbits + 7
	flushed = flush_bytes(out, acc, total)
	remaining = total.bitwise_and(7)
	if remaining == 0 {
		flushed
	} else {
		flushed.append(acc.shr_wrap(total - remaining).to_u8_wrap())
	}
}

# The hash table's first `hash_size` entries map hash to the most recent position
# with that hash. The next `window_size` entries chain each position (indexed
# by position mod window) to the previous position with the same hash.
# Positions are stored as position + 1, where 0 means empty.
insert_slot : List(U64), U64, U64 -> List(U64)
insert_slot = |table, slot, pos| {
	previous_head = table.get(slot) ?? 0
	with_head = 
		match table.set(slot, pos + 1) {
			Ok(t) => t
			Err(_) => []
		}
	match with_head.set(hash_size + pos.bitwise_and(window_size - 1), previous_head) {
		Ok(t) => t
		Err(_) => []
	}
}

insert_range : List(U8), U64, U64, List(U64) -> List(U64)
insert_range = |input, pos, end, table|
	if pos >= end or pos + min_match > input.len() {
		table
	} else {
		insert_range(input, pos + 1, end, insert_slot(table, hash3(input, pos), pos))
	}

# Walk the hash chain newest-candidate-first, keeping the longest match.
# Within the window, chain links are always older positions, so the distance
# check also guarantees termination alongside the depth limit.
chain_search : List(U8), U64, List(U64), U64, U64, U64, U64, U64 -> { len : U64, dist : U64 }
chain_search = |input, pos, table, candidate, depth, nice_match, best_len, best_dist|
	if candidate == 0 or depth == 0 or pos + 1 - candidate > window_size or best_len >= nice_match {
		{ len: best_len, dist: best_dist }
	} else {
		start = candidate - 1
		# A match can only beat best_len if it also matches at that offset
		promising = input.get(start + best_len) == input.get(pos + best_len)
		matched = if promising {
			match_length(input, start, pos, 0)
		} else {
			0
		}
		next_candidate = table.get(hash_size + start.bitwise_and(window_size - 1)) ?? 0
		if matched > best_len {
			chain_search(input, pos, table, next_candidate, depth - 1, nice_match, matched, pos - start)
		} else {
			chain_search(input, pos, table, next_candidate, depth - 1, nice_match, best_len, best_dist)
		}
	}

# The fixed Huffman code for a literal/length symbol (RFC 1951 section
# 3.2.6).
fixed_literal_code : U16 -> { code : U32, len : U8 }
fixed_literal_code = |symbol|
	if symbol <= 143 {
		{ code: 0x30 + symbol.to_u32(), len: 8 }
	} else if symbol <= 255 {
		{ code: 0x190 + (symbol - 144).to_u32(), len: 9 }
	} else if symbol <= 279 {
		{ code: (symbol - 256).to_u32(), len: 7 }
	} else {
		{ code: 0xC0 + (symbol - 280).to_u32(), len: 8 }
	}

# Hash of the 3-byte sequence at `pos`, used to index the chain heads.
hash3 : List(U8), U64 -> U64
hash3 = |input, pos| {
	b0 = (input.get(pos) ?? 0).to_u64()
	b1 = (input.get(pos + 1) ?? 0).to_u64()
	b2 = (input.get(pos + 2) ?? 0).to_u64()
	(((b0.shl_wrap(16) + b1.shl_wrap(8) + b2) * 2654435761).shr_wrap(15)).bitwise_and(hash_size - 1)
}

# How many bytes match between the candidate and current position, capped at
# the maximum match length and the end of input.
match_length : List(U8), U64, U64, U64 -> U64
match_length = |input, candidate, pos, matched|
	if matched >= max_match or pos + matched >= input.len() {
		matched
	} else if input.get(candidate + matched) == input.get(pos + matched) {
		match_length(input, candidate, pos, matched + 1)
	} else {
		matched
	}

# Lazy matching (zlib's deflate_slow): at each position find the longest
# match, but emit the previous position's deferred match only if the current
# one is no better. Otherwise emit one literal and defer the decision again.
# `pending` means position pos - 1 is not yet emitted, and its match candidate
# is prev_len/prev_dist (prev_len < min_match means it has none).
compress_loop : List(U8), U64, List(U64), List(U8), U64, U8, Bool, U64, U64, List(U64), List(U64), U64, U64, U64 -> List(U8)
compress_loop = |input, pos, table, out, acc, nbits, pending, prev_len, prev_dist, len_codes, dist_codes, max_chain, max_lazy, nice_match|
	if pos >= input.len() {
		if pending {
			bits = literal_bits(input.get(pos - 1) ?? 0)
			combined = acc.bitwise_or(bits.value.shl_wrap(nbits))
			total = nbits + bits.count
			flushed = flush_bytes(out, combined, total)
			remaining = total.bitwise_and(7)
			finish_stream(flushed, combined.shr_wrap(total - remaining), remaining)
		} else {
			finish_stream(out, acc, nbits)
		}
	} else {
		can_match = pos + min_match <= input.len()

		slot = if can_match {
			hash3(input, pos)
		} else {
			0
		}

		candidate = if can_match {
			table.get(slot) ?? 0
		} else {
			0
		}

		searchable = if can_match {
			insert_slot(table, slot, pos)
		} else {
			table
		}

		found = 
			if can_match and prev_len < max_lazy {
				chain_search(input, pos, searchable, candidate, max_chain, nice_match, 0, 0)
			} else {
				{ len: 0, dist: 0 }
			}
		cur_len = if found.len == min_match and found.dist > too_far {
			0
		} else {
			found.len
		}

		if pending and prev_len >= min_match and cur_len <= prev_len {
			# The deferred match wins: emit it and skip past what it covers
			bits = match_bits(prev_len, prev_dist, len_codes, dist_codes)
			combined = acc.bitwise_or(bits.value.shl_wrap(nbits))
			total = nbits + bits.count
			flushed = flush_bytes(out, combined, total)
			remaining = total.bitwise_and(7)
			next_pos = pos - 1 + prev_len
			filled = insert_range(input, pos + 1, next_pos, searchable)
			compress_loop(input, next_pos, filled, flushed, combined.shr_wrap(total - remaining), remaining, Bool.False, 0, 0, len_codes, dist_codes, max_chain, max_lazy, nice_match)
		} else if pending {
			# The current match is better (or neither matched): emit one
			# literal and defer the current candidate
			bits = literal_bits(input.get(pos - 1) ?? 0)
			combined = acc.bitwise_or(bits.value.shl_wrap(nbits))
			total = nbits + bits.count
			flushed = flush_bytes(out, combined, total)
			remaining = total.bitwise_and(7)
			compress_loop(input, pos + 1, searchable, flushed, combined.shr_wrap(total - remaining), remaining, Bool.True, cur_len, found.dist, len_codes, dist_codes, max_chain, max_lazy, nice_match)
		} else {
			compress_loop(input, pos + 1, searchable, out, acc, nbits, Bool.True, cur_len, found.dist, len_codes, dist_codes, max_chain, max_lazy, nice_match)
		}
	}

# --- Tests ---

# Round trips through compress then decompress

expect Deflate.decompress(Deflate.compress([], Balanced)) == Ok([])

expect {
	original = "Hello, World!".to_utf8()
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

# Repetitive data exercises LZ77 matches, including overlapping copies
expect {
	original = "abcabcabcabcabcabcabcabcabcabc".to_utf8()
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

expect {
	original = List.repeat(0x42, 1000)
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

# All byte values, including 144-255 which use 9-bit fixed codes
expect {
	original = List.repeat(0, 256).map_with_index(|_, index| index.to_u8_wrap())
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

# Repetitive data must actually shrink
expect {
	original = List.repeat(0x42, 1000)
	Deflate.compress(original, Balanced).len() < 100
}

# Lazy matching: "bcdef" at position 6 tempts a greedy 5-byte match, but the
# 6-byte "abcdef" starting one byte later is better
expect {
	original = "xabcde bcdefq abcdefq".to_utf8()
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

# Chain search: several earlier occurrences of the same 3-byte prefix, where
# only an older one continues into a long match
expect {
	original = "the cat, the cow, the crow, then the cricket saw the cow again".to_utf8()
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

# Structured pseudo-random bytes round trip (mixed literals and matches)
expect {
	original = List.repeat(0, 3000).map_with_index(|_, index| (index * 31 + index.shr_wrap(5) * 7).to_u8_wrap())
	Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
}

# Every level round-trips the same input
expect {
	original = "the cat, the cow, the crow, then the cricket saw the cow again".to_utf8()
	Deflate.decompress(Deflate.compress(original, Fastest)) == Ok(original)
		and Deflate.decompress(Deflate.compress(original, Balanced)) == Ok(original)
			and Deflate.decompress(Deflate.compress(original, Smallest)) == Ok(original)
}

# Deeper search never produces a larger stream than a shallower one
expect {
	original = List.repeat(0, 3000).map_with_index(|_, index| (index * 31 + index.shr_wrap(5) * 7).to_u8_wrap())
	fastest = Deflate.compress(original, Fastest).len()
	balanced = Deflate.compress(original, Balanced).len()
	smallest = Deflate.compress(original, Smallest).len()
	smallest <= balanced and balanced <= fastest
}

# A stored block, hand-built: bfinal=1 btype=00, LEN=5, NLEN=~5, "Hello"
expect {
	stored = [0x01, 0x05, 0x00, 0xFA, 0xFF, 0x48, 0x65, 0x6C, 0x6C, 0x6F]
	Deflate.decompress(stored) == Ok("Hello".to_utf8())
}

# An empty fixed-Huffman block: bfinal=1, btype=01, then the 7-bit
# end-of-block code. In total 10 bits, 0b011 then 0000000, packing to [0x03, 0x00]
expect Deflate.decompress([0x03, 0x00]) == Ok([])

# Truncated stream reports UnexpectedEnd
expect {
	match Deflate.decompress([0x03]) {
		Err(UnexpectedEnd) => Bool.True
		_ => Bool.False
	}
}

# Reserved block type 11 reports CorruptData
expect {
	match Deflate.decompress([0x07]) {
		Err(CorruptData) => Bool.True
		_ => Bool.False
	}
}

# Real-world interop: a dynamic-Huffman stream produced by gzip -9 (header
# and trailer stripped), decompressed and compared to the original text
expect {
	fixture = [141, 78, 203, 21, 130, 64, 12, 188, 91, 197, 20, 224, 163, 9, 91, 160, 129, 0, 1, 86, 96, 179, 38, 89, 22, 173, 94, 228, 61, 46, 94, 244, 54, 191, 55, 51, 245, 200, 120, 228, 208, 78, 104, 84, 74, 68, 47, 27, 238, 121, 73, 6, 89, 89, 225, 187, 61, 211, 235, 137, 78, 134, 10, 245, 255, 97, 208, 64, 33, 130, 98, 247, 141, 42, 220, 100, 73, 202, 102, 65, 34, 138, 232, 100, 104, 216, 28, 101, 228, 8, 231, 205, 161, 156, 152, 220, 16, 220, 120, 238, 175, 63, 56, 246, 246, 149, 52, 72, 54, 20, 122, 218, 49, 117, 10, 105, 166, 150, 109, 191, 166, 146, 135, 81, 178, 31, 47, 79, 247, 179, 86, 93, 222]
	original = [84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114, 111, 119, 110, 32, 102, 111, 120, 32, 106, 117, 109, 112, 115, 32, 111, 118, 101, 114, 32, 116, 104, 101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 46, 32, 84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114, 111, 119, 110, 32, 102, 111, 120, 32, 106, 117, 109, 112, 115, 32, 111, 118, 101, 114, 32, 116, 104, 101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 32, 97, 103, 97, 105, 110, 32, 97, 110, 100, 32, 97, 103, 97, 105, 110, 32, 97, 110, 100, 32, 97, 103, 97, 105, 110, 46, 32, 67, 111, 109, 112, 114, 101, 115, 115, 105, 111, 110, 32, 119, 111, 114, 107, 115, 32, 98, 101, 115, 116, 32, 119, 104, 101, 110, 32, 116, 101, 120, 116, 32, 114, 101, 112, 101, 97, 116, 115, 32, 105, 116, 115, 101, 108, 102, 44, 32, 114, 101, 112, 101, 97, 116, 115, 32, 105, 116, 115, 101, 108, 102, 44, 32, 114, 101, 112, 101, 97, 116, 115, 32, 105, 116, 115, 101, 108, 102, 32, 105, 110, 32, 118, 97, 114, 105, 111, 117, 115, 32, 119, 97, 121, 115, 32, 97, 110, 100, 32, 118, 97, 114, 105, 111, 117, 115, 32, 112, 108, 97, 99, 101, 115, 32, 116, 104, 114, 111, 117, 103, 104, 111, 117, 116, 32, 116, 104, 101, 32, 118, 97, 114, 105, 111, 117, 115, 32, 116, 101, 120, 116, 46, 10]
	Deflate.decompress(fixture) == Ok(original)
}
