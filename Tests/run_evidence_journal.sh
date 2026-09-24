#!/bin/bash
# The review surface's model half (T11's first half): what a suggestion pass saw
# becomes the timed spans a review row shows, and the one click that answers a
# chip answers its evidence too.
#
# Proves what a reviewer would otherwise have to take on trust: one pass writes
# all its tags without clobbering itself; a span's confidence is the chip's own
# margin rather than an invented 1.0; a tag whose source owns no per-frame times
# invents none; the reason counts only frames the plan looked at; accept, reject
# and ignore each land on the claim as themselves; a re-run replaces its own
# unanswered rows and leaves an answered one exactly where the human left it;
# staleness is judged against the file as it is now; and nothing here throws at a
# caller — a broken store lands in `problem` and the pass keeps its suggestions.
#
# No network, no model, no Xcode: the sightings are hand-made and the store is
# real SQLite in a temporary root.
#
# Usage: Tests/run_evidence_journal.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_evidence_journal.swift" "$work/evidence_journal"
"$work/evidence_journal"
