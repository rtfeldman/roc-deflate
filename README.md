# roc-deflate

DEFLATE (RFC 1951) compression and decompression in pure Roc.

- `Deflate.compress` produces a raw DEFLATE stream any inflate implementation can read, using hash-chain LZ77 with lazy matching at one of three effort levels: `Fastest`, `Balanced`, or `Smallest`.
- `Deflate.decompress` reads all three DEFLATE block types (stored, fixed Huffman, dynamic Huffman), so it handles streams produced by `zlib`, `gzip`, and ZIP tools.

View the API documentation at [https://niclas-ahden.github.io/roc-deflate/](https://niclas-ahden.github.io/roc-deflate/).

## Quick start

```roc
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
    deflate: "https://github.com/niclas-ahden/roc-deflate/releases/download/0.3.0/9d7QRzf6vgYMDqXgTsL5sTh8B475yeL8KUAp8TJKs2Q5.tar.zst",
}

import pf.Stdout
import pf.OsStr
import deflate.Deflate

main! = |args| {
    # Compresses the text you pass on the command line, or this line if you
    # pass none
    original = match args.get(1) {
        Ok(arg) => OsStr.display(arg).to_utf8()
        Err(_) => "Bootcut Jeans, salmon shirt, I have a skin routine and my elbows hurt.".to_utf8()
    }

    compressed = Deflate.compress(original, Balanced)
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
```

See [examples](examples/) for a runnable program.

## Choosing a level

You've got `Fastest`, `Balanced`, or `Smallest` and here's how they compare to `gzip` on the [Silesia corpus](http://mattmahoney.net/dc/silesia.html) (times are only meant to give an indication in relation to one another):

| Level      | Compressed size  | Ratio | Time   |
| ---------- | ---------------- | ----- | ------ |
| `Fastest`  | 85,524,903 bytes | 40.4% | ~4.7 s |
| `Balanced` | 78,420,875 bytes | 37.0% | ~6.9 s |
| `Smallest` | 76,929,989 bytes | 36.3% | ~15 s  |
| gzip -1    | 77,366,708 bytes | 36.5% | ~1.3 s |
| gzip -6    | 68,227,965 bytes | 32.2% | ~4.3 s |
| gzip -9    | 67,631,990 bytes | 31.9% | ~10 s  |

There is plenty of room to improve both performance and compression. See this as a starting point 👍

Try it on your machine: `nix develop -c ./benchmark/run.roc` (downloads and verifies the corpus on first run).

## Testing

`./tests.roc` (or `nix develop -c ./tests.roc` to get `gzip` and coreutils from the flake instead of the host) runs:

- the package's `expect` blocks, which round-trip our compress and decompress against each other,
- gzip interop in both directions on a deterministic 1 MB generated-text corpus: every level's output must decode byte-identically under real `gzip`, and real `gzip`'s streams at `-1`/`-6`/`-9` (differing block structures) must inflate byte-identically under our decompressor, and
- a compression-ratio gate on the [Canterbury corpus](tests/corpus/): each level's output must stay within a ratchet ceiling, so a change that worsens compression fails the build.

Quite nice!
