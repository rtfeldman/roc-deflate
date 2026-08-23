## Pieces shared by the Lempel-Ziv matchfinders, ported from libdeflate's
## `matchfinder_common.h`.
##
## Positions are stored as signed 16-bit values relative to a base that slides
## through the input a window at a time. A position at or below the current
## cutoff is out of the window, so one signed comparison rejects both stale
## entries and the never-written initial value; that is why the tables start
## filled with the most negative position rather than zero.
Matchfinder := [].{

	window_order : U64
	window_order = 15

	window_size : U64
	window_size = 32768

	## The value every table entry starts at: far enough back that it can never
	## pass the in-window test.
	initval : I16
	initval = -32768

	## Hash a sequence prefix held in the low bits of a 32-bit value.
	##
	## The multiply spreads the prefix over the whole word and the shift keeps
	## the high bits of the product, which carry the most randomness.
	lz_hash : U32, U64 -> U64
	lz_hash = |seq, num_bits|
		seq.times_wrap(0x1E35A7BD).shr_zf_wrap((32 - num_bits).to_u8_wrap()).to_u64()

	## Fill a table with the initial out-of-window position.
	init_table : U64 -> List(I16)
	init_table = |num_entries|
		List.repeat(Matchfinder.initval, num_entries)

	## Slide a table back by one window, so its entries stay relative to the
	## new base.
	##
	## Entries that would pass below the most negative position stay there,
	## permanently out of the window. The subtraction is written without a
	## branch: an already-negative entry contributes zero, and the sign bit is
	## then set unconditionally, which is a saturating subtract of the window
	## size.
	rebase_table : List(I16) -> Try(List(I16), [CompressBug])
	rebase_table = |table0| {
		var $table = table0
		n = List.len($table)
		var $i = 0.U64
		while $i < n {
			v = List.get($table, $i) ?? 0
			slid = Matchfinder.initval.bitwise_or(v.bitwise_and(v.shr_wrap(15).bitwise_not()))
			$table = match List.set($table, $i, slid) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok($table)
	}

	## Absolute input index of a stored position, which the tables hold
	## relative to the sliding base and so may be negative.
	match_index : U64, I16 -> U64
	match_index = |in_base, node| {
		abs : I64
		abs = in_base.to_i64_wrap().plus_wrap(node.to_i64())
		abs.to_u64_wrap()
	}

	## Number of bytes at `match_at` that equal the bytes at `str_at`, counting
	## the `start_len` bytes the caller already matched and stopping at
	## `max_len`.
	##
	## Whole words are compared at a time and the first differing word is
	## located by its lowest set bit, so a mismatch costs one count rather than
	## a byte loop. The caller guarantees `max_len` bytes are readable at both
	## positions, which is what makes the word reads safe.
	lz_extend : List(U8), U64, U64, U64, U64 -> U64
	lz_extend = |input, str_at, match_at, start_len, max_len| {
		var $len = start_len
		var $diff = 0.U64
		var $found = 0.U64

		# Four unrolled word steps cover most matches without loop overhead.
		if max_len - $len >= 32 {
			var $step = 0.U64
			while $step < 4 and $found == 0 {
				v = (U64.from_le_bytes(input, match_at + $len) ?? 0)
					.bitwise_xor(U64.from_le_bytes(input, str_at + $len) ?? 0)
				if v != 0 {
					$diff = v
					$found = 1
				} else {
					$len = $len + 8
					$step = $step + 1
				}
			}
		} else {
		}

		while $found == 0 and $len + 8 <= max_len {
			v = (U64.from_le_bytes(input, match_at + $len) ?? 0)
				.bitwise_xor(U64.from_le_bytes(input, str_at + $len) ?? 0)
			if v != 0 {
				$diff = v
				$found = 1
			} else {
				$len = $len + 8
			}
		}

		if $found == 1 {
			$len + $diff.count_trailing_zero_bits().to_u64().shr_zf_wrap(3)
		} else {
			var $tail = $len
			while $tail < max_len
				and (List.get(input, match_at + $tail) ?? 0) == (List.get(input, str_at + $tail) ?? 0) {
				$tail = $tail + 1
			}
			$tail
		}
	}
}
