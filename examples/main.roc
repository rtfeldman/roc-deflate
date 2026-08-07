app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.22.1/DobkAk7zNyqAgqh2Riaj5c5DtWtKhd5iVYE5RFa6izcd.tar.zst",
	deflate: "../package/main.roc",
}

import pf.Stdout
import deflate.Deflate

main! = |_| {
	original = "Bootcut Jeans, salmon shirt, I have a skin routine and my elbows hurt.".to_utf8()

	compressed = Deflate.compress(original, 6) ? |_| Exit(1)
	Stdout.line!("Compressed ${original.len().to_str()} bytes to ${compressed.len().to_str()}")?

	match Deflate.decompress(compressed) {
		Ok(decompressed) =>
			if decompressed == original {
				Stdout.line!("Round-trip successful")?
			} else {
				Stdout.line!("Round-trip mismatch!")?
			}
		Err(CorruptData) => Stdout.line!("Corrupt DEFLATE stream")?
		Err(UnexpectedEnd) => Stdout.line!("Truncated DEFLATE stream")?
	}

	Ok({})
}
