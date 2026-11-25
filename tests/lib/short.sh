# Shell helpers over short.py, for a POSIX sh battery. Source this file from the battery with
# short.py beside it (both copied from embabel-worlds/realm-spec battery/, see its README):
#
#   . "$(dirname "$0")/lib/short.sh"
#
# A figure is only the realm's when the engine says the answer is whole. Each helper prints the
# figure, or REFUSED: <why> / PARTIAL <figure>: <the engine's reason>, which no check expects, so
# an exact-equality check fails with the engine's own words.
#
#   n     ANSWER [COLUMN]  the figure in COLUMN (default n) of a query answer's first row
#   rows  ANSWER           how many rows a view answered
#   whole ANSWER SNIPPET   run Python SNIPPET over the parsed answer, as `d`, only when it is whole
#   short_of ANSWER        nothing when whole, else the verdict line (for `[ -n "$(short_of "$R")" ]`)
#
# Answers are passed as arguments and handed to Python on stdin, never on its command line: a
# whole book of rows is past the system's argument limit, and `echo` under macOS's /bin/sh turns
# the `\n` escapes inside JSON strings into raw newlines.
SHORT_LIB=${SHORT_LIB:-$(CDPATH='' cd -- "$(dirname -- "${SHORT_SH:-$0}")" && pwd)/lib}
SHORT_PY_FILE=${SHORT_PY_FILE:-$SHORT_LIB/short.py}
[ -f "$SHORT_PY_FILE" ] || { echo "short.sh: no short.py at $SHORT_PY_FILE (set SHORT_PY_FILE)" >&2; exit 2; }
SHORT_PY=$(cat "$SHORT_PY_FILE")
export SHORT_PY
n() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.loads(sys.stdin.read(), strict=False); v = figure_of(d, '${2:-n}')
print(short(d, v) or v)"; }
rows() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.loads(sys.stdin.read(), strict=False); v = figure_of(d)
print(short(d, v) or v)"; }
whole() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.loads(sys.stdin.read(), strict=False); s = short(d)
if s: print(s); sys.exit(0)
$2"; }
short_of() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.loads(sys.stdin.read(), strict=False); print(short(d) or '', end='')"; }
