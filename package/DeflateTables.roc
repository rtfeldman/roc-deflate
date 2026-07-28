## The fixed tables DEFLATE (RFC 1951) defines, transcribed from libdeflate so
## the two agree symbol for symbol.
##
## These are not arbitrary: the length and offset slot bases, together with the
## extra-bit counts, are what turn a (length, offset) pair into the symbol and
## extra bits that go on the wire, so any disagreement here changes the output
## stream rather than merely its size.
DeflateTables := [].{
	## Number of extra bits carried by each precode symbol. Only the three
	## run-length symbols (16, 17, 18) have any.
	extra_precode_bits : List(U8)
	extra_precode_bits = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7]

	## Extra bits for each length slot, indexed from litlen symbol 257.
	extra_length_bits : List(U8)
	extra_length_bits = [
		0, 0, 0, 0, 0, 0, 0, 0,
		1, 1, 1, 1, 2, 2, 2, 2,
		3, 3, 3, 3, 4, 4, 4, 4,
		5, 5, 5, 5, 0,
	]

	## Smallest match length encoded by each length slot.
	length_slot_base : List(U32)
	length_slot_base = [
		3, 4, 5, 6, 7, 8, 9, 10,
		11, 13, 15, 17, 19, 23, 27, 31,
		35, 43, 51, 59, 67, 83, 99, 115,
		131, 163, 195, 227, 258,
	]

	## Extra bits for each offset slot.
	extra_offset_bits : List(U8)
	extra_offset_bits = [
		0, 0, 0, 0, 1, 1, 2, 2,
		3, 3, 4, 4, 5, 5, 6, 6,
		7, 7, 8, 8, 9, 9, 10, 10,
		11, 11, 12, 12, 13, 13,
	]

	## Smallest match offset encoded by each offset slot.
	offset_slot_base : List(U32)
	offset_slot_base = [
		1, 2, 3, 4, 5, 7, 9, 13,
		17, 25, 33, 49, 65, 97, 129, 193,
		257, 385, 513, 769, 1025, 1537, 2049, 3073,
		4097, 6145, 8193, 12289, 16385, 24577,
	]

	## Litlen symbol that ends a block.
	end_of_block : U64
	end_of_block = 256

	## First litlen symbol that encodes a match length.
	first_len_sym : U64
	first_len_sym = 257

	num_litlen_syms : U64
	num_litlen_syms = 288

	num_offset_syms : U64
	num_offset_syms = 32

	## Block types, as they appear in the 2-bit BTYPE field.
	blocktype_uncompressed : U64
	blocktype_uncompressed = 0

	blocktype_static : U64
	blocktype_static = 1

	blocktype_dynamic : U64
	blocktype_dynamic = 2

	## The codeword lengths of the fixed ("static") litlen code, which RFC 1951
	## defines rather than transmitting.
	static_litlen_lens : List(U8)
	static_litlen_lens = {
		var $out = List.with_capacity(288)
		var $i = 0.U64
		while $i < 288 {
			len = if $i < 144 {
				8
			} else if $i < 256 {
				9
			} else if $i < 280 {
				7
			} else {
				8
			}
			$out = List.append($out, len)
			$i = $i + 1
		}
		$out
	}

	## The static offset code: all 32 symbols, 5 bits each.
	static_offset_lens : List(U8)
	static_offset_lens = List.repeat(5.U8, 32)

	## Length slot for a match length, i.e. which litlen symbol encodes it.
	length_slot : U64 -> U64
	length_slot = |length| {
		var $slot = 0.U64
		var $i = 1.U64
		while $i < 29 {
			base = (List.get(DeflateTables.length_slot_base, $i) ?? 0).to_u64()
			if base <= length {
				$slot = $i
			} else {
			}
			$i = $i + 1
		}
		$slot
	}

	## Offset slot for a match offset.
	offset_slot : U64 -> U64
	offset_slot = |offset| {
		var $slot = 0.U64
		var $i = 1.U64
		while $i < 30 {
			base = (List.get(DeflateTables.offset_slot_base, $i) ?? 0).to_u64()
			if base <= offset {
				$slot = $i
			} else {
			}
			$i = $i + 1
		}
		$slot
	}
}
