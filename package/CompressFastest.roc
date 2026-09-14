import HtMatchfinder
import Block
import BitWriter
import DeflateTables

## Level 1 compression, ported from libdeflate's `deflate_compress_fastest`.
##
## Greedy: take whatever match the hash-table finder returns, otherwise emit a
## literal. No lazy matching, and no block splitting -- blocks simply end at
## 65535 bytes or 8192 matches, whichever comes first. That is what makes this
## the fast setting, and it is also why it is the simplest of the three to make
## byte-identical.
CompressFastest := [].{

	## A block ends once it reaches this many bytes.
	soft_max_block_length : U64
	soft_max_block_length = 65535

	## ...or this many matches.
	seq_store_length : U64
	seq_store_length = 8192

	## A block is never split closer than this to the end; a short tail is
	## folded into the previous block instead.
	min_block_length : U64
	min_block_length = 5000

	max_match_len : U64
	max_match_len = 258

	## `nice_match_length` at level 1.
	nice_match_length : U64
	nice_match_length = 32

	## Where the current block may end at the latest. A tail shorter than
	## `min_block_length` is absorbed rather than left as its own block.
	choose_max_block_end : U64, U64 -> U64
	choose_max_block_end = |block_begin, data_len|
		if data_len - block_begin < CompressFastest.soft_max_block_length + CompressFastest.min_block_length {
			data_len
		} else {
			block_begin + CompressFastest.soft_max_block_length
		}

	## Inputs at or below this size skip compression entirely and go out as
	## stored blocks. libdeflate computes it as `55 - level * 4`, so level 1
	## passes through 51 bytes; the compressed form rarely wins on inputs that
	## small once the block header is counted.
	max_passthrough_size : U64
	max_passthrough_size = 51

	compress : List(U8) -> List(U8)
	compress = |data|
		if List.len(data) <= CompressFastest.max_passthrough_size {
			CompressFastest.compress_none(data)
		} else {
			CompressFastest.compress_blocks(data)
		}

	## Stored blocks only, byte-aligned from the start. Mirrors
	## `deflate_compress_none`.
	compress_none : List(U8) -> List(U8)
	compress_none = |data| {
		n = List.len(data)
		if n == 0 {
			# An empty final stored block: BFINAL=1, BTYPE=00, LEN=0, NLEN=FFFF.
			[1, 0, 0, 255, 255]
		} else {
			var $out = List.with_capacity(n + 5 * (n // 65535 + 1))
			var $pos = 0.U64
			var $more = True
			while $more {
				left = n - $pos
				len = left.min(65535)
				bfinal = if left <= 65535 {
					1.U8
				} else {
					0
				}
				$out = List.append($out, bfinal)
				$out = List.append($out, len.to_u8_wrap())
				$out = List.append($out, len.shr_zf_wrap(8).to_u8_wrap())
				$out = List.append($out, len.bitwise_not().to_u8_wrap())
				$out = List.append($out, len.bitwise_not().shr_zf_wrap(8).to_u8_wrap())
				$out = List.concat($out, List.sublist(data, { start: $pos, len: len }))
				$pos = $pos + len
				if $pos >= n {
					$more = False
				} else {}
			}
			$out
		}
	}

	compress_blocks : List(U8) -> List(U8)
	compress_blocks = |data| {
		data_len = List.len(data)
		if data_len == 0 {
			# An empty input still needs a final block for the stream to be
			# well formed.
			freqs = Block.empty_freqs
			eob = DeflateTables.end_of_block
			f = { ..freqs, litlen: List.set(freqs.litlen, eob, 1) ?? freqs.litlen }
			BitWriter.finish(Block.flush(BitWriter.new(16), data, 0, 0, [], f, True))
		} else {
			var $w = BitWriter.new(data_len // 2 + 64)
			var $mf = HtMatchfinder.init({})
			var $next_hash = 0.U64
			var $pos = 0.U64

			while $pos < data_len {
				block_begin = $pos
				max_block_end = CompressFastest.choose_max_block_end(block_begin, data_len)

				var $seqs = List.with_capacity(CompressFastest.seq_store_length)
				var $litrun = 0.U64
				var $litlen_freqs = List.repeat(0.U32, DeflateTables.num_litlen_syms)
				var $offset_freqs = List.repeat(0.U32, DeflateTables.num_offset_syms)
				var $in_block = True

				while $in_block {
					remaining = data_len - $pos
					if remaining < HtMatchfinder.required_nbytes {
						# Too little left to hash; the rest are literals.
						var $k = 0.U64
						while $k < remaining {
							lit = (List.get(data, $pos) ?? 0).to_u64()
							$litlen_freqs = CompressFastest.bump($litlen_freqs, lit)
							$litrun = $litrun + 1
							$pos = $pos + 1
							$k = $k + 1
						}
						$in_block = False
					} else {
						max_len = remaining.min(CompressFastest.max_match_len)
						nice_len = CompressFastest.nice_match_length.min(max_len)
						r = HtMatchfinder.longest_match($mf, data, $pos, max_len, nice_len, $next_hash)
						$mf = r.finder
						$next_hash = r.next_hash

						if r.found.length != 0 {
							len = r.found.length
							off = r.found.offset
							len_slot = DeflateTables.length_slot(len)
							off_slot = DeflateTables.offset_slot(off)
							$litlen_freqs = CompressFastest.bump($litlen_freqs, DeflateTables.first_len_sym + len_slot)
							$offset_freqs = CompressFastest.bump($offset_freqs, off_slot)
							$seqs = List.append($seqs, { litrunlen: $litrun, length: len, offset: off })
							$litrun = 0
							# Catch the table up over the bytes the match covered.
							sk = HtMatchfinder.skip_bytes($mf, data, $pos + 1, len - 1, data_len, $next_hash)
							$mf = sk.finder
							$next_hash = sk.next_hash
							$pos = $pos + len
						} else {
							lit = (List.get(data, $pos) ?? 0).to_u64()
							$litlen_freqs = CompressFastest.bump($litlen_freqs, lit)
							$litrun = $litrun + 1
							$pos = $pos + 1
						}

						if $pos >= max_block_end or List.len($seqs) >= CompressFastest.seq_store_length {
							$in_block = False
						} else {}
					}
				}

				# Trailing literals with no match after them still form a
				# sequence, which is how the block writer knows to emit them.
				seqs = if $litrun > 0 {
					List.append($seqs, { litrunlen: $litrun, length: 0, offset: 0 })
				} else {
					$seqs
				}
				eob = DeflateTables.end_of_block
				litlen_with_eob = CompressFastest.bump($litlen_freqs, eob)
				freqs = { litlen: litlen_with_eob, offset: $offset_freqs }

				$w = Block.flush($w, data, block_begin, $pos - block_begin, seqs, freqs, $pos >= data_len)
			}

			BitWriter.finish($w)
		}
	}

	bump : List(U32), U64 -> List(U32)
	bump = |freqs, idx|
		List.set(freqs, idx, (List.get(freqs, idx) ?? 0) + 1) ?? freqs
}
