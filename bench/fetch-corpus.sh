#!/usr/bin/env bash
# Download the benchmark corpus listed in bench/corpus.tsv into
# bench/corpus/<category>/<id>.<ext>, verifying each file's sha256.
#
# Usage: bench/fetch-corpus.sh
# Env:   CORPUS_TSV  optional path to an alternative corpus TSV (for tests).
#
# TSV columns: id, category, url, license, author, sha256 (header row skipped).
# Per file: "skipped" if present with the right hash, "re-downloaded" if present
# with a wrong hash, "downloaded" if absent. A fresh download whose hash does
# not match is an error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="${CORPUS_TSV:-$SCRIPT_DIR/corpus.tsv}"
CORPUS_DIR="$SCRIPT_DIR/corpus"
USER_AGENT="UnderpressuredBench/0.1 (image optimizer benchmark corpus fetch)"

TMP_FILE=""
cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

die() {
  echo "fetch-corpus: error: $*" >&2
  exit 1
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

[[ -f "$TSV" ]] || die "corpus file not found: $TSV"

# Emit id, category, url, sha256 for each data row. awk keeps empty fields
# intact, unlike a whitespace-collapsing read on tabs.
while IFS=$'\t' read -r id category url sha256; do
  [[ -n "$id" ]] || die "row with empty id in $TSV"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe id '$id' in $TSV"
  [[ "$category" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe category '$category' for id $id"
  [[ -n "$url" ]] || die "empty url for id $id"
  [[ "$sha256" =~ ^[A-Fa-f0-9]{64}$ ]] || die "invalid sha256 for id $id: '$sha256'"
  sha256="$(printf '%s' "$sha256" | tr '[:upper:]' '[:lower:]')"

  # Extension comes from the URL path, ignoring any query or fragment.
  path="${url%%[?#]*}"
  base="${path##*/}"
  [[ "$base" == *.* ]] || die "no file extension in url for id $id: $url"
  ext="$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ext" =~ ^[a-z0-9]+$ ]] || die "unsupported extension '$ext' for id $id"

  dest_dir="$CORPUS_DIR/$category"
  dest="$dest_dir/$id.$ext"
  rel="corpus/$category/$id.$ext"
  state="downloaded"

  if [[ -f "$dest" ]]; then
    if [[ "$(sha256_of "$dest")" == "$sha256" ]]; then
      echo "skipped          $rel"
      continue
    fi
    state="re-downloaded"
  fi

  mkdir -p "$dest_dir"
  # Same directory as dest so mv is an atomic rename. A plain name (not
  # mktemp) keeps the normal umask-based file mode.
  TMP_FILE="$dest_dir/.$id.$$.part"
  rm -f "$TMP_FILE"
  if ! curl -fsSL --retry 8 --retry-delay 60 --retry-all-errors -A "$USER_AGENT" -o "$TMP_FILE" "$url"; then
    die "download failed for id $id: $url"
  fi

  actual="$(sha256_of "$TMP_FILE")"
  if [[ "$actual" != "$sha256" ]]; then
    die "sha256 mismatch for id $id ($url): expected $sha256, got $actual"
  fi

  mv -f "$TMP_FILE" "$dest"
  TMP_FILE=""
  echo "$(printf '%-16s' "$state") $rel"
done < <(awk -F'\t' 'NR > 1 && NF > 0 { print $1 "\t" $2 "\t" $3 "\t" $6 }' "$TSV")
