#!/usr/bin/env bash
# Render the three-point verdict: roc-deflate against a C reference library at
# matched settings.
#
#     ./benchmark/compare.sh roc.tsv c.tsv
#
# Both arguments are TSV files in the shared schema (see benchmark/c/README.md).
# Columns are located by name from the header row, so the two sides only have to
# agree on column *names*, not order, and either may carry extra columns.
#
# Required columns: setting, op, orig, comp, best_ns
#
# Rows whose setting is "-" are diagnostics from off-triple levels and are
# ignored. Rows are aggregated over every file in the corpus: sizes and times are
# summed, so the reported ratio and throughput are the corpus totals rather than
# an average of per-file numbers, which would over-weight the small files.
#
# The goal is that all six cells (three settings x compress/decompress) pass on
# both ratio and throughput. Exit status is 0 only if they all do, so this is
# usable as a gate.
#
# Tolerances:
#   --ratio-tol=PP    percentage points of compression ratio (default 0.5)
#   --speed-tol=PCT   percent of the C library's throughput (default 5)
#
# If an input has an "engine" column naming more than one engine, pass
# --engine=NAME to pick which one to compare against; summing two engines into
# one bucket would report a blend of both, which means nothing.
set -euo pipefail

ratio_tol=0.5
speed_tol=5
engine=""
files=()

for arg in "$@"; do
	case "$arg" in
		--ratio-tol=*) ratio_tol="${arg#*=}" ;;
		--speed-tol=*) speed_tol="${arg#*=}" ;;
		--engine=*) engine="${arg#*=}" ;;
		-*) echo "unknown option $arg" >&2; exit 2 ;;
		*) files+=("$arg") ;;
	esac
done

if [ "${#files[@]}" -ne 2 ]; then
	echo "usage: compare.sh [--ratio-tol=PP] [--speed-tol=PCT] [--engine=NAME] <roc.tsv> <c.tsv>" >&2
	exit 2
fi

for f in "${files[@]}"; do
	[ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done

awk -v roc_file="${files[0]}" -v c_file="${files[1]}" \
    -v ratio_tol="$ratio_tol" -v speed_tol="$speed_tol" -v want_engine="$engine" '
	function need(name,   i) {
		if (!(name in col))
			fail("input " FILENAME " has no \"" name "\" column")
		return col[name]
	}
	# awk runs END even on exit, so flag the abort and have END stand down;
	# otherwise a bad input would print an empty table over the real error and
	# replace the exit status with the verdict.
	function fail(msg) {
		print "compare.sh: " msg > "/dev/stderr"
		aborted = 1
		exit 2
	}

	FNR == 1 {
		side = (FILENAME == roc_file) ? "roc" : "c"
		delete col
		for (i = 1; i <= NF; i++)
			col[$i] = i
		c_setting = need("setting"); c_op = need("op")
		c_orig = need("orig"); c_comp = need("comp"); c_ns = need("best_ns")
		# Optional: present in the C harness output, absent from a single-engine
		# file. Without it there is nothing to disambiguate.
		c_engine = ("engine" in col) ? col["engine"] : 0
		next
	}

	{
		setting = $c_setting
		if (setting == "-" || setting == "")
			next

		# Summing two engines into one bucket would produce a meaningless blend,
		# so track which appear and make the caller choose if there is a choice.
		if (c_engine) {
			if (want_engine != "" && $c_engine != want_engine)
				next
			engines[side SUBSEP $c_engine] = 1
		}

		key = side SUBSEP setting SUBSEP $c_op
		orig[key] += $c_orig
		comp[key] += $c_comp
		ns[key]   += $c_ns
	}

	END {
		if (aborted)
			exit 2

		for (k in engines) {
			split(k, parts, SUBSEP)
			n[parts[1]]++
			names[parts[1]] = (names[parts[1]] == "") ? parts[2] : names[parts[1]] " " parts[2]
		}
		for (s in n)
			if (n[s] > 1)
				fail("the " s " input mixes engines (" names[s] "); " \
				     "pass --engine=NAME to pick one")

		settings[1] = "fastest"; settings[2] = "balanced"; settings[3] = "smallest"
		ops[1] = "compress"; ops[2] = "decomp"

		printf "== three-point verdict  (ratio within %.2fpp, throughput within %.1f%%)\n\n", ratio_tol, speed_tol
		printf "  %-9s %-9s %8s %8s %9s %10s %10s %9s   %s\n", \
		       "setting", "op", "roc", "c", "delta", "roc", "c", "delta", "verdict"
		printf "  %-9s %-9s %8s %8s %9s %10s %10s %9s\n", \
		       "", "", "ratio", "ratio", "(pp)", "MB/s", "MB/s", "(%)"

		all_pass = 1
		missing = 0
		for (s = 1; s <= 3; s++) {
			for (o = 1; o <= 2; o++) {
				setting = settings[s]; op = ops[o]
				rk = "roc" SUBSEP setting SUBSEP op
				ck = "c" SUBSEP setting SUBSEP op

				if (!(rk in orig) || !(ck in orig)) {
					which = (rk in orig) ? "c" : ((ck in orig) ? "roc" : "both")
					printf "  %-9s %-9s %54s   MISSING (%s)\n", setting, op, "", which
					missing = 1
					all_pass = 0
					continue
				}

				# Corpus totals, not an average of per-file numbers.
				r_ratio = 100 * comp[rk] / orig[rk]
				c_ratio = 100 * comp[ck] / orig[ck]
				r_mbps = 1000 * orig[rk] / ns[rk]
				c_mbps = 1000 * orig[ck] / ns[ck]

				# Ratio: lower is better, so roc minus c positive means worse.
				d_ratio = r_ratio - c_ratio
				# Throughput: higher is better, as a percent of the C number.
				d_speed = 100 * (r_mbps - c_mbps) / c_mbps

				ratio_ok = (d_ratio <= ratio_tol)
				speed_ok = (d_speed >= -speed_tol)

				verdict = "PASS"
				if (!ratio_ok && !speed_ok) verdict = "FAIL (ratio, speed)"
				else if (!ratio_ok)         verdict = "FAIL (ratio)"
				else if (!speed_ok)         verdict = "FAIL (speed)"
				if (verdict != "PASS") all_pass = 0

				printf "  %-9s %-9s %7.2f%% %7.2f%% %+9.2f %10.1f %10.1f %+8.1f%%   %s\n", \
				       setting, op, r_ratio, c_ratio, d_ratio, r_mbps, c_mbps, d_speed, verdict
			}
		}

		print ""
		if (all_pass)
			print "  all six points match within tolerance"
		else if (missing)
			print "  incomplete: some points had no data on one side"
		exit all_pass ? 0 : 1
	}
' "${files[0]}" "${files[1]}"
