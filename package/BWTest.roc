import BitWriter

BWTest := [].{
	placeholder : U8
	placeholder = 0
}

# LSB-first packing: bits fill each byte from the bottom up.
expect BitWriter.finish(BitWriter.add(BitWriter.new(8), 1, 1)) == [1]
expect BitWriter.finish(BitWriter.add(BitWriter.add(BitWriter.new(8), 1, 1), 1, 1)) == [3]
expect BitWriter.finish(BitWriter.add(BitWriter.new(8), 5, 3)) == [5]

# A value spanning a byte boundary splits low bits first.
expect BitWriter.finish(BitWriter.add(BitWriter.add(BitWriter.new(8), 0, 6), 3, 4)) == [192, 0]

# An empty stored block: BFINAL=1, BTYPE=00, align, LEN=0, NLEN=0xFFFF.
expect {
	w = BitWriter.new(16)
	w2 = BitWriter.add(w, 1, 1)
	w3 = BitWriter.add(w2, 0, 2)
	w4 = BitWriter.align(w3)
	w5 = BitWriter.append_bytes(w4, [0, 0, 255, 255])
	BitWriter.finish(w5)
} == [1, 0, 0, 255, 255]

# flush leaves the partial byte pending; finish pads it.
expect BitWriter.flush(BitWriter.add(BitWriter.new(8), 255, 12)).bytes == [255]
expect BitWriter.flush(BitWriter.add(BitWriter.new(8), 255, 12)).bitcount == 4
