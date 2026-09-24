# Sourced by pre-commit and commit-msg: where the vocabulary comes from, and
# the one scan both of them run. Not a hook itself; git only runs files named
# after hooks.
#
# The words are not in this repository. They used to be, on one line of
# pre-commit, which made the file written to keep them out of the public repo
# the one place that published every one of them. Now they live in a file
# outside the repo, named in git config:
#
#   git config photopipeline.vocabfile /path/to/vocab.txt
#
# One word per line; blank lines and lines starting with # are skipped. Each
# is matched case-insensitively as a whole word, with an underscore counted as
# a break between words: grep's \b does not, so a name like <word>_1.jpg or a
# variable like <word>_boxes went straight past it.
#
# Three answers, and only one of them lets a commit through unchecked:
#   unset    a stranger's clone. There is no list of theirs to guard, so the
#            check is skipped and says so in one line rather than blocking them.
#   ok       the words, joined for grep -E.
#   broken   the config names a file that is missing, unreadable or empty, or
#            the scan cannot find a word it was just given. Refuse: a guard
#            that passes because its list went missing is the failure this
#            replaced, and it passed every commit for days that way once.

vocab_load() {
  emulate -L zsh
  setopt extendedglob
  VOCAB_STATE=unset VOCAB_WORDS="" VOCAB_WHY="" VOCAB_FILE=""
  VOCAB_FILE=$(git config --type=path --get photopipeline.vocabfile 2>/dev/null) || VOCAB_FILE=""
  [[ -z "$VOCAB_FILE" ]] && return 0
  VOCAB_STATE=broken
  if [[ ! -r "$VOCAB_FILE" || ! -f "$VOCAB_FILE" ]]; then
    VOCAB_WHY="photopipeline.vocabfile names $VOCAB_FILE, which is not a file this hook can read"
    return 0
  fi
  local -a ws
  local l
  for l in "${(@f)$(<"$VOCAB_FILE")}"; do
    l=${l%%$'\r'}
    l=${${l##[[:space:]]#}%%[[:space:]]#}
    [[ -z "$l" || "$l" == \#* ]] && continue
    ws+=("$l")
  done
  if (( ! ${#ws} )); then
    VOCAB_WHY="photopipeline.vocabfile names $VOCAB_FILE, and it lists no words"
    return 0
  fi
  VOCAB_WORDS=${(j:|:)ws}
  # Prove the scan works on this machine before trusting a clean answer from
  # it. The grep here was once ugrep, which read part of the filter as a
  # repetition operator and died; the pipeline swallowed the error and every
  # commit passed. A word the list itself supplies has to be found.
  if ! print -r -- "x ${ws[1]} y" | grep -qiE "\\b(${VOCAB_WORDS})\\b" 2>/dev/null; then
    VOCAB_WHY="grep -E on this machine does not find a word from $VOCAB_FILE in a line made to contain it"
    return 0
  fi
  VOCAB_STATE=ok
}

# vocab_scan TEXT: sets VOCAB_HITS to the matching lines, numbered (with any
# underscore shown as a space). Returns 0 when the text is clean, 1 when it is
# not, and 2 when grep itself failed, which the callers treat as a refusal and
# never as clean.
vocab_scan() {
  local rc=0
  VOCAB_HITS=$(print -r -- "$1" | tr '_' ' ' | grep -inE "\\b(${VOCAB_WORDS})\\b" 2>&1) || rc=$?
  (( rc == 0 )) && return 1
  (( rc == 1 )) && return 0
  return 2
}
