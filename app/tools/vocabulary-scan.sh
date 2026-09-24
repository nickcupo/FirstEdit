#!/usr/bin/env bash
# Two lists, two scopes.
#
# 1. The private extension's domain vocabulary, over EVERY TRACKED FILE —
#    source, comments, strings, test names, fixture data, file names, in app/
#    and in pipeline/, tests/, docs/ and the markdown at the root. It scanned
#    app/ alone, which left the engine, the tests and every document a person
#    reads first with no automated gate over them at all. What goes public is
#    what git tracks, so that is the list it walks. This repo is public and
#    that vocabulary belongs to a repo that is not. The list is
#    not written out again here: it comes from the same place the hooks read it
#    from, because a second copy of it is a second thing to forget to update,
#    and because writing it out again would put the words in one more public
#    file. That place is the file `git config photopipeline.vocabfile` names,
#    which lives outside this repository (see .githooks/vocab.zsh). A clone
#    with no such file is a stranger's, and there is nothing of his to guard:
#    the scan says so in one line and passes. A file that is named and cannot
#    be read is a broken guard and refuses.
#
# 2. The retired words of DESIGN.md §2.13, over what a person can actually read
#    — the string catalog and the design's own strings file. Not over the whole
#    tree: "rating", "tier" and "CSV" are the engine's field names and the
#    app has to spell them to decode them. They are banned from a label.
#
# Usage:
#   tools/vocabulary-scan.sh            scan every tracked file, non-zero on a hit
#   tools/vocabulary-scan.sh --words    print the private list's regex and exit
#   tools/vocabulary-scan.sh <path>...  scan these paths instead
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app=$(dirname "$here")
repo=$(dirname "$app")
hook="$repo/.githooks/pre-commit"

vocabfile=$(git -C "$repo" config --type=path --get photopipeline.vocabfile 2>/dev/null || true)
if [[ -n "$vocabfile" ]]; then
  if [[ ! -f "$vocabfile" || ! -r "$vocabfile" ]]; then
    echo "vocabulary-scan: photopipeline.vocabfile names $vocabfile, which is not a file this can read" >&2
    exit 2
  fi
  private=$(grep -vE '^[[:space:]]*(#|$)' "$vocabfile" | sed 's/[[:space:]]*$//' | paste -sd'|' -)
else
  # Before the list moved out of the repository it was one line of the hook.
  private=$(sed -n "s/^words='\(.*\)'$/\1/p" "$hook" 2>/dev/null | head -1)
fi
if [[ -z "$private" ]]; then
  echo "vocabulary-scan: no photopipeline.vocabfile in git config, so the private list is not scanned"
  private=""
fi
# A guard that passes because its own scan is broken is worse than no guard:
# the grep here was once ugrep, which read part of the pattern as a repetition
# operator and died, and every commit went through clean for days.
if [[ -n "$private" ]]; then
  first=${private%%|*}
  if ! printf 'x %s y\n' "$first" | grep -qiE -e "\b(${private})\b" 2>/dev/null; then
    echo "vocabulary-scan: grep on this machine cannot find a word from the list in a line made to hold it" >&2
    exit 2
  fi
fi

if [[ "${1:-}" == "--words" ]]; then
  printf '%s\n' "$private"
  exit 0
fi

# Nothing to scan for, and nothing of his to protect: a stranger's clone.
if [[ -z "$private" ]]; then
  retired_only=1
else
  retired_only=0
fi

targets=("$@")

# grep on this machine is ugrep, which reads a leading ^+ as a repetition
# operator; every pattern here is passed with -e so none of them is read as a
# flag, and the pre-commit hook's own note about that is why.
fail=0

skip_binary() { grep -vE '\.(png|jpg|jpeg|icns|car|pdf|mp4|npz|whl|zip)$'; }
if [[ ${#targets[@]} -eq 0 ]]; then
  # What goes public is what git tracks. A file nobody committed is not in the
  # tree a stranger clones, and a file git ignores never will be.
  files=$(git -C "$repo" ls-files -z | tr '\0' '\n' | skip_binary | sed "s|^|$repo/|")
else
  files=$(find "${targets[@]}" \
            -path '*/.build' -prune -o \
            -path '*/snapshots' -prune -o \
            -type f -print | skip_binary)
fi

hits=""
namehits=""
if (( ! retired_only )); then
  # An underscore is a word break here and \b does not treat it as one, so a
  # name like <word>_1.jpg or a variable like <word>_boxes went straight past.
  hits=$(printf '%s\n' "$files" | while read -r f; do
    [[ -n "$f" ]] || continue
    tr '_' ' ' < "$f" 2>/dev/null | grep -inE -e "\b(${private})\b" | sed "s|^|${f#"$repo"/}:|"
  done)
  # File names count too.
  namehits=$(printf '%s\n' "$files" | tr '_' ' ' | grep -iE -e "(${private})" || true)
fi

if [[ -n "$hits" || -n "$namehits" ]]; then
  echo "vocabulary-scan: the private extension's vocabulary is in the tree"
  [[ -n "$hits" ]] && printf '%s\n' "$hits" | head -20 | sed 's/^/    /'
  [[ -n "$namehits" ]] && printf '%s\n' "$namehits" | head -10 | sed 's/^/    file name: /'
  echo "  This repo is public. Put it in the private extension, or reword it."
  fail=1
fi

# The retired words, over what is read on screen.
retired='answer key|AUC|held out|duplicates?|dups?|veto|embeddings?|\./pl'
# Every Strings.swift under the library, not just the design's: a crew that
# puts its own sentences in its own folder is read by a person just the same.
strings=$(find "$app/Resources" "$app/Sources/PipelineKit" -type f \
            \( -name '*.xcstrings' -o -name '*Strings.swift' \) 2>/dev/null)
if [[ -n "$strings" ]]; then
  rhits=$(printf '%s\n' "$strings" | while read -r f; do
    [[ -n "$f" ]] || continue
    grep -inE -e "\b(${retired})\b" "$f" 2>/dev/null | sed "s|^|${f#"$repo"/}:|"
  done)
  if [[ -n "$rhits" ]]; then
    echo "vocabulary-scan: a retired word (DESIGN.md §2.13) is in a string a person reads"
    printf '%s\n' "$rhits" | head -20 | sed 's/^/    /'
    fail=1
  fi
fi

if [[ $fail -eq 0 ]]; then
  echo "vocabulary-scan: clean ($(printf '%s\n' "$files" | grep -c . ) files)"
fi
exit $fail
