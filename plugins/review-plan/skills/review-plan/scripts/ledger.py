#!/usr/bin/env python3
"""Edit the findings ledger at the top of a review-plan review document.

    ledger.py <review.md> add 'ID|Dimension|Severity|Finding|Plan §|Status' [...]
        Insert rows (one argument per row, pipe-separated) above <!-- ledger-end -->.
    ledger.py <review.md> set ID=status [ID=status ...]
        Replace the Status cell of existing rows, e.g. P1-S1=fixed 'P1-S2=duplicate (P1-C1)'.
    ledger.py <review.md> open
        Print the non-terminal blocking rows (what a verify pass must rule on); exit 1 if any.

Terminal statuses: verified, conceded, withdrawn, duplicate (...). For non-blocking rows,
fixed and pushed-back are terminal too. The orchestrator is the only writer of this file.
"""
import re
import sys

TERMINAL = ("verified", "conceded", "withdrawn", "duplicate")
END = "<!-- ledger-end -->"


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__); return 2
    path, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    text = open(path, encoding="utf-8").read()
    if END not in text:
        print(f"{path}: no {END} sentinel", file=sys.stderr); return 2
    if cmd == "add":
        rows = "".join("| " + " | ".join(c.strip() for c in a.split("|")) + " |\n" for a in args)
        text = text.replace(END, rows + END, 1)
    elif cmd == "set":
        for a in args:
            rid, status = a.split("=", 1)
            pat = re.compile(r"^(\| " + re.escape(rid) + r" \|.*\| )([^|]+)(\|\s*)$", re.M)
            if not pat.search(text):
                print(f"no ledger row {rid}", file=sys.stderr); return 1
            text = pat.sub(lambda m: m.group(1) + status.strip() + " " + m.group(3), text, count=1)
    elif cmd == "open":
        ledger = text.split("## Findings ledger", 1)[1].split(END, 1)[0]
        open_rows = [ln for ln in ledger.splitlines()
                     if ln.startswith("| P") and "| blocking |" in ln
                     and not any(ln.rstrip(" |").rsplit("|", 1)[-1].strip().startswith(s) for s in TERMINAL)]
        print("\n".join(open_rows) if open_rows else "ledger clean")
        return 1 if open_rows else 0
    else:
        print(__doc__); return 2
    open(path, "w", encoding="utf-8").write(text)
    print("ok", cmd, len(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
