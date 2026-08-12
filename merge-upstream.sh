#!/usr/bin/env bash
#
# Merge the latest release tag from upstream (mikf/gallery-dl) into this fork.
#
# This fork re-adds extractors that upstream removed (exhentai, hitomi,
# nhentai, hentaifoundry, ...). Those are additive files upstream never
# touches, so merges are normally conflict-free.
#
# Usage:
#   ./merge-upstream.sh              # merge latest release tag
#   ./merge-upstream.sh v1.32.3      # merge a specific tag
#   ./merge-upstream.sh --branch     # merge upstream/master tip instead
#   ./merge-upstream.sh --dry-run    # show what would happen, change nothing
#
set -euo pipefail

UPSTREAM="upstream"
BRANCH="master"

# Files this fork owns. Used to verify they survive the merge.
FORK_FILES=(
    gallery_dl/extractor/exhentai.py
    gallery_dl/extractor/hdoujin.py
    gallery_dl/extractor/hentaifoundry.py
    gallery_dl/extractor/hentaihand.py
    gallery_dl/extractor/hentainexus.py
    gallery_dl/extractor/hitomi.py
    gallery_dl/extractor/nhentai.py
    gallery_dl/extractor/schalenetwork.py
)

DRY_RUN=0
USE_BRANCH=0
TARGET=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --branch)  USE_BRANCH=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)        echo "unknown option: $arg" >&2; exit 2 ;;
        *)         TARGET="$arg" ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------

git remote get-url "$UPSTREAM" >/dev/null 2>&1 \
    || die "no '$UPSTREAM' remote. Add it with:
    git remote add $UPSTREAM https://github.com/mikf/gallery-dl.git"

[ -n "$(git status --porcelain)" ] \
    && die "working tree is dirty. Commit or stash first."

current="$(git rev-parse --abbrev-ref HEAD)"
[ "$current" = "$BRANCH" ] \
    || die "on branch '$current', expected '$BRANCH'."

# Refuse to run mid-merge.
git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    && die "a merge is already in progress. Resolve it or run: git merge --abort"

# --- fetch -------------------------------------------------------------

info "Fetching $UPSTREAM ..."
git fetch "$UPSTREAM" --tags --prune

# --- resolve merge target ----------------------------------------------

if [ "$USE_BRANCH" -eq 1 ]; then
    REF="$UPSTREAM/$BRANCH"
elif [ -n "$TARGET" ]; then
    git rev-parse -q --verify "refs/tags/$TARGET" >/dev/null \
        || die "tag '$TARGET' not found."
    REF="$TARGET"
else
    # Latest release tag by version sort, matching the vX.Y.Z convention.
    REF="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
    [ -n "$REF" ] || die "could not determine latest tag."
fi

info "Merge target: $REF ($(git rev-parse --short "$REF"))"

# Already up to date? merge-base == target means it is an ancestor.
if git merge-base --is-ancestor "$REF" HEAD; then
    info "Already up to date — '$REF' is an ancestor of HEAD. Nothing to do."
    exit 0
fi

info "Incoming commits: $(git rev-list --count HEAD.."$REF")"
git log --oneline --no-merges HEAD.."$REF" | head -20
echo

# Warn if upstream touched any file this fork owns.
touched=""
for f in "${FORK_FILES[@]}"; do
    if ! git diff --quiet HEAD "$REF" -- "$f" 2>/dev/null; then
        touched="$touched $f"
    fi
done
[ -n "$touched" ] && warn "upstream touched fork-owned files:$touched"

if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run — stopping before merge."
    exit 0
fi

# --- merge -------------------------------------------------------------

before="$(git rev-parse HEAD)"

info "Merging $REF ..."
if ! git merge --no-edit "$REF"; then
    warn "Merge produced conflicts. Conflicting paths:"
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    warn "Resolve them, then: git commit"
    warn "Or abort with:      git merge --abort"
    exit 1
fi

# --- verify ------------------------------------------------------------

missing=""
for f in "${FORK_FILES[@]}"; do
    [ -f "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    warn "fork-owned files missing after merge:$missing"
    warn "Recover them with: git checkout $before -- <file>"
fi

info "Merged $REF. HEAD is now $(git rev-parse --short HEAD)."

if git -c core.fileMode=false diff --quiet "$before" HEAD; then
    info "No file changes resulted."
else
    git diff --stat "$before" HEAD | tail -15
fi

echo
info "Review, then push with: git push origin $BRANCH"
