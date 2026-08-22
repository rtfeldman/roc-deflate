## LSB-first bit output, following libdeflate's bitstream discipline.
##
## DEFLATE packs codewords least-significant-bit first within each byte, and
## codewords are not byte aligned, so output goes through a bit buffer: bits
## accumulate in a 64-bit word and whole bytes are flushed out of the bottom.
##
## libdeflate keeps `bitbuf` and `bitcount` in local variables and writes bytes
## with macros, specifically so the compiler does not reload them through a
## pointer on every symbol. The same shape is kept here -- one record threaded
## through, flushed only when it could overflow -- because that is what makes it
## possible to add several codewords between flushes, which is where the
## performance work will go.
BitWriter := [].{
	## `bitbuf` holds `bitcount` pending bits in its low bits; everything above
	## them is zero. `bytes` is the output written so far.
	Writer : { bytes : List(U8), bitbuf : U64, bitcount : U8 }

	new : U64 -> Writer
	new = |capacity| { bytes: List.with_capacity(capacity), bitbuf: 0, bitcount: 0 }

	## Add `count` bits of `value` (which must fit in `count` bits).
	##
	## The caller is responsible for flushing often enough that `bitcount` stays
	## under 64; that is why libdeflate pairs every run of `ADD_BITS` with a
	## `FLUSH_BITS` and asserts the total fits. `flush` here is cheap enough to
	## call after each symbol, and callers that batch must do the same counting.
	add : Writer, U64, U8 -> Writer
	add = |w, value, count|
		if count == 0 {
			w
		} else {
			{
				..w,
				bitbuf: w.bitbuf.bitwise_or(value.shl_wrap(w.bitcount)),
				bitcount: w.bitcount + count,
			}
		}

	## Write out every whole byte sitting in the bit buffer.
	flush : Writer -> Writer
	flush = |w| {
		var $bytes = w.bytes
		var $bitbuf = w.bitbuf
		var $bitcount = w.bitcount
		while $bitcount >= 8 {
			$bytes = List.append($bytes, $bitbuf.to_u8_wrap())
			$bitbuf = $bitbuf.shr_zf_wrap(8)
			$bitcount = $bitcount - 8
		}
		{ bytes: $bytes, bitbuf: $bitbuf, bitcount: $bitcount }
	}

	## Pad with zeroes up to the next byte boundary and flush.
	align : Writer -> Writer
	align = |w| {
		flushed = BitWriter.flush(w)
		if flushed.bitcount == 0 {
			flushed
		} else {
			{ bytes: List.append(flushed.bytes, flushed.bitbuf.to_u8_wrap()), bitbuf: 0, bitcount: 0 }
		}
	}

	## Append whole bytes. Only valid on a byte boundary, which is where stored
	## blocks put their payload.
	append_bytes : Writer, List(U8) -> Writer
	append_bytes = |w, data| { ..w, bytes: List.concat(w.bytes, data) }

	## Finish the stream: pad the last partial byte with zeroes.
	finish : Writer -> List(U8)
	finish = |w| BitWriter.align(w).bytes
}
