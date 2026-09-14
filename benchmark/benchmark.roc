## Benchmark the Deflate implementation on the Silesia corpus, with real gzip on
## the same bytes for reference.
##
## Each of the 12 Silesia files is compressed on its own, the way the corpus is
## meant to be measured, and the sizes and times are summed. `Deflate.compress`
## is timed *in-process*, so the number is compression work alone. gzip is timed
## as a subprocess reading each file directly (`gzip -c <lvl> <file>`), so only
## its compressed stdout crosses the pipe and there is no pipe-buffer deadlock.
##
## The sole argument is the directory holding the extracted Silesia files;
## benchmark/run.roc downloads and unpacks them, then invokes this binary:
##
##     roc build --opt=speed benchmark/benchmark.roc && ./benchmark/benchmark benchmark/.corpus
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	deflate: "../package/main.roc",
}

import pf.Stdout
import pf.Path
import pf.Cmd
import pf.Utc
import pf.IOErr exposing [IOErr]
import pf.OsStr exposing [OsStr]
import deflate.Deflate

# The 12 Silesia files, in the corpus's canonical order.
names = [
	"dickens", "mozilla", "mr", "nci", "ooffice", "osdb",
	"reymont", "samba", "sao", "webster", "x-ray", "xml",
]

Timed : { size : U64, ms : U128 }
FileResult : {
	name : Str,
	orig : U64,
	fastest : Timed,
	balanced : Timed,
	smallest : Timed,
	gzip1 : Timed,
	gzip6 : Timed,
	gzip9 : Timed,
}

main! = |args| {
	dir_os = match args.get(1) {
		Ok(raw) => OsStr.from_raw(raw)
		Err(_) => OsStr.from_str("benchmark/.corpus")
	}
	dir = Path.from_os_str(dir_os)

	Stdout.line!("== corpus: Silesia, 12 files compressed individually")?
	results = bench_all!(dir, names, [])?
	Stdout.line!("")?

	# Per-file breakdown: shows how each data type (text, binary, image)
	# compresses on its own.
	Stdout.line!("== per file (compressed bytes)")?
	Stdout.line!("${pad_right("file", 9)} ${pad_left("orig", 11)} ${pad_left("fastest", 11)} ${pad_left("balanced", 11)} ${pad_left("smallest", 11)}")?
	print_rows!(results)?
	total_orig = results.fold(0, |acc, r| acc + r.orig)
	Stdout.line!("${pad_right("TOTAL", 9)} ${pad_left(total_orig.to_str(), 11)} ${pad_left(sum_size(results, |r| r.fastest).to_str(), 11)} ${pad_left(sum_size(results, |r| r.balanced).to_str(), 11)} ${pad_left(sum_size(results, |r| r.smallest).to_str(), 11)}")?
	Stdout.line!("")?

	# Summary: total compressed size, ratio, and total time per level.
	Stdout.line!("== roc-deflate (in-process, summed over files)")?
	report!("fastest", total_orig, sum_timed(results, |r| r.fastest))?
	report!("balanced", total_orig, sum_timed(results, |r| r.balanced))?
	report!("smallest", total_orig, sum_timed(results, |r| r.smallest))?
	Stdout.line!("")?

	Stdout.line!("== gzip (reference)")?
	report!("gzip-1", total_orig, sum_timed(results, |r| r.gzip1))?
	report!("gzip-6", total_orig, sum_timed(results, |r| r.gzip6))?
	report!("gzip-9", total_orig, sum_timed(results, |r| r.gzip9))?

	Ok({})
}

# Benchmark every file in turn, accumulating one FileResult each.
bench_all! : Path.Path, List(Str), List(FileResult) => Try(List(FileResult), [Exit(I32), StdoutErr(IOErr), ..])
bench_all! = |dir, remaining, acc|
	match remaining {
		[] => Ok(acc)
		[name, .. as rest] => {
			r = bench_file!(dir, name)?
			bench_all!(dir, rest, acc.append(r))
		}
	}

# Read one Silesia file and time our compressor at each level plus gzip -1/-6/-9.
bench_file! : Path.Path, Str => Try(FileResult, [Exit(I32), StdoutErr(IOErr), ..])
bench_file! = |dir, name| {
	file_path = dir.join(name)
	bytes = Path.read_bytes!(file_path) ? |_| Exit(1)
	file_os = OsStr.from_raw(Path.to_raw(file_path))
	Ok({
		name,
		orig: bytes.len(),
		fastest: bench_level!(bytes, Fastest),
		balanced: bench_level!(bytes, Balanced),
		smallest: bench_level!(bytes, Smallest),
		gzip1: bench_gzip!(file_os, "-1")?,
		gzip6: bench_gzip!(file_os, "-6")?,
		gzip9: bench_gzip!(file_os, "-9")?,
	})
}

# Compress once and measure wall-clock milliseconds around it. `size` is read
# before the finish timestamp so the compression is fully forced first.
bench_level! : List(U8), [Fastest, Balanced, Smallest] => Timed
bench_level! = |bytes, level| {
	start = Utc.now!()
	out = Deflate.compress(bytes, level)
	size = out.len()
	finish = Utc.now!()
	{ size, ms: Utc.delta_as_millis(finish, start) }
}

# Time gzip reading the file and writing to stdout (which we capture). gzip does
# its own file read, so nothing large is fed to its stdin.
bench_gzip! : OsStr, Str => Try(Timed, [Exit(I32), ..])
bench_gzip! = |file_os, level| {
	start = Utc.now!()
	cmd = Cmd.new(OsStr.from_str("gzip")).args([OsStr.from_str(level), OsStr.from_str("-c"), file_os])
	out = cmd.exec_output_bytes!() ? |_| Exit(1)
	size = out.stdout_bytes.len()
	finish = Utc.now!()
	Ok({ size, ms: Utc.delta_as_millis(finish, start) })
}

# One per-file breakdown row: original size and each level's compressed size.
print_rows! : List(FileResult) => Try({}, [StdoutErr(IOErr), ..])
print_rows! = |results|
	match results {
		[] => Ok({})
		[r, .. as rest] => {
			Stdout.line!("${pad_right(r.name, 9)} ${pad_left(r.orig.to_str(), 11)} ${pad_left(r.fastest.size.to_str(), 11)} ${pad_left(r.balanced.size.to_str(), 11)} ${pad_left(r.smallest.size.to_str(), 11)}")?
			print_rows!(rest)
		}
	}

# Total compressed size for one level across every file.
sum_size : List(FileResult), (FileResult -> Timed) -> U64
sum_size = |results, pick| results.fold(0, |acc, r| acc + pick(r).size)

# Total { size, ms } for one level across every file.
sum_timed : List(FileResult), (FileResult -> Timed) -> Timed
sum_timed = |results, pick|
	results.fold({ size: 0, ms: 0 }, |acc, r| {
		t = pick(r)
		{ size: acc.size + t.size, ms: acc.ms + t.ms }
	})

# One summary row: name, compressed size, ratio vs original, and total time.
report! : Str, U64, Timed => Try({}, [StdoutErr(IOErr), ..])
report! = |name, orig, { size, ms }| {
	pct = (size * 10000) // orig
	ratio = "${(pct // 100).to_str()}.${pad2(pct % 100)}%"
	Stdout.line!("${pad_right(name, 10)} ${pad_left(size.to_str(), 11)} bytes  ${pad_left(ratio, 7)}  ${pad_left(ms.to_str(), 7)} ms")
}

pad2 : U64 -> Str
pad2 = |n| if n < 10 { "0${n.to_str()}" } else { n.to_str() }

pad_left : Str, U64 -> Str
pad_left = |s, width| {
	n = s.to_utf8().len()
	pad = if n >= width { 0 } else { width - n }
	"${repeat_str(" ", pad)}${s}"
}

pad_right : Str, U64 -> Str
pad_right = |s, width| {
	n = s.to_utf8().len()
	pad = if n >= width { 0 } else { width - n }
	"${s}${repeat_str(" ", pad)}"
}

repeat_str : Str, U64 -> Str
repeat_str = |s, n| if n == 0 { "" } else { "${s}${repeat_str(s, n - 1)}" }
