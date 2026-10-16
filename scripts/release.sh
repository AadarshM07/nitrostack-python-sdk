#!/usr/bin/env bash
# Release the SDK to PyPI from this machine.
#
# publish.yml uploads only through PyPI trusted publishing, and the Bump
# version workflow can't open its release PR (the org doesn't let GitHub
# Actions create pull requests). This script does both by hand.
#
#   1. Get a release branch, either way:
#        - the Bump version workflow already pushed `release/X.Y.Z`:
#            git switch release/X.Y.Z && git pull
#        - or have this script make one from origin/main:
#            scripts/release.sh --bump patch     (or minor / major)
#   2. On that branch:  scripts/release.sh
#        checks, tests, builds, uploads to PyPI (asks first), verifies the
#        install, and opens the release PR if there isn't one.
#   3. Merge the release PR (publish.yml sees the version on PyPI and skips).
#   4. scripts/release.sh --tag     tags origin/main vX.Y.Z and pushes the tag.
#
# Options:
#   --bump KIND    patch|minor|major: create release/<next> from origin/main
#   --skip-tests   don't run the test suite before building
#   --yes          don't ask before uploading
#   --dry-run      stop before anything leaves this machine (no push, upload,
#                  PR or tag); --bump still creates the branch locally
#   --tag          step 4 only
#
# Needs uv, gh (for the PR) and a PyPI token, in ~/.pypirc ([pypi] with
# username __token__) or in TWINE_USERNAME=__token__ / TWINE_PASSWORD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUMP=""
SKIP_TESTS=0
YES=0
DRY_RUN=0
TAG_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bump)
      BUMP="${2:-}"
      shift
      ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --tag) TAG_ONLY=1 ;;
    -h | --help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (see --help)" >&2
      exit 2
      ;;
  esac
  shift
done
case "$BUMP" in "" | patch | minor | major) ;; *)
  echo "--bump takes patch, minor or major" >&2
  exit 2
  ;;
esac

step() { printf '\n==> %s\n' "$*"; }
fail() {
  printf '\nerror: %s\n' "$*" >&2
  exit 1
}

# uv: a pyenv shim fails inside this repo when the pinned .python-version
# isn't installed in pyenv, so fall back to known install locations.
find_uv() {
  local candidate
  for candidate in "${UV:-}" "$(command -v uv 2>/dev/null || true)" \
    "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv \
    "$HOME"/.pyenv/versions/*/bin/uv; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}
UV="$(find_uv)" || fail "uv not found. Install it (https://docs.astral.sh/uv/) or set UV=/path/to/uv."
UVX="$(dirname "$UV")/uvx"
[ -x "$UVX" ] || UVX="$UV tool run"
PY=("$UV" run --no-project --quiet python)

project_version() { "${PY[@]}" -c 'import re,sys; print(re.search(r"(?m)^version = \"([^\"]+)\"", sys.stdin.read()).group(1))'; }
# Exit 0 when VERSION is on PyPI.
on_pypi() { curl -fs -o /dev/null "https://pypi.org/pypi/nitrostack/$1/json"; }
tag_exists() { git rev-parse -q --verify "refs/tags/v$1" >/dev/null || [ -n "$(git ls-remote --tags origin "refs/tags/v$1")" ]; }

step "Fetching origin"
git fetch -q --tags origin

# --- Step 4: tag the merged release -------------------------------------
if [ "$TAG_ONLY" = 1 ]; then
  VERSION="$(git show origin/main:pyproject.toml | project_version)"
  echo "origin/main is at $VERSION"
  on_pypi "$VERSION" || fail "$VERSION isn't on PyPI. Release it first (scripts/release.sh on its release branch)."
  tag_exists "$VERSION" && fail "Tag v$VERSION already exists."
  if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run: would tag origin/main ($(git rev-parse --short origin/main)) as v$VERSION and push it."
    exit 0
  fi
  git tag -a "v$VERSION" origin/main -m "nitrostack $VERSION"
  git push -q origin "v$VERSION"
  echo "Tagged and pushed v$VERSION."
  exit 0
fi

[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "Uncommitted changes. Commit or stash them first."

# --- Step 1 (optional): make the release branch -------------------------
if [ -n "$BUMP" ]; then
  step "Creating a $BUMP release branch from origin/main"
  MAIN_VERSION="$(git show origin/main:pyproject.toml | project_version)"
  on_pypi "$MAIN_VERSION" || fail "origin/main's version $MAIN_VERSION isn't on PyPI yet. Release it as is (no --bump)."
  # bump_version plans from the checked-out tree, so check out origin/main;
  # go back to where we were if anything below fails.
  ORIG_REF="$(git branch --show-current)"
  ORIG_REF="${ORIG_REF:-$(git rev-parse HEAD)}"
  trap 'git switch -q "$ORIG_REF" 2>/dev/null || git switch -q --detach "$ORIG_REF"' ERR
  git switch -q --detach origin/main
  NEXT="$("${PY[@]}" scripts/bump_version.py --root . --bump "$BUMP" | tail -n 1)"
  [ -n "$NEXT" ] || {
    git switch -q "$ORIG_REF" 2>/dev/null || git switch -q --detach "$ORIG_REF"
    fail "PyPI's project index doesn't list $MAIN_VERSION yet (it's cached for up to 15 minutes after a release). Try again shortly."
  }
  git rev-parse -q --verify "refs/heads/release/$NEXT" >/dev/null && fail "Branch release/$NEXT already exists locally."
  [ -z "$(git ls-remote --heads origin "release/$NEXT")" ] || fail "release/$NEXT already exists on origin. Use it: git switch release/$NEXT"
  git switch -q -c "release/$NEXT"
  "${PY[@]}" scripts/bump_version.py --root . --bump "$BUMP" --write >/dev/null
  git add pyproject.toml uv.lock
  git commit -q -m "chore(release): $NEXT"
  trap - ERR
  echo "Created release/$NEXT with the version bump."
  if [ "$DRY_RUN" = 0 ]; then
    git push -q -u origin "release/$NEXT"
  fi
fi

# --- Step 2: check, test, build, upload ---------------------------------
BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || fail "Not on a branch. Switch to the release branch first."
VERSION="$(project_version <pyproject.toml)"

step "Checking nitrostack $VERSION on $BRANCH"
[ "$BRANCH" != main ] || fail "On main. Run this on the release branch (release/X.Y.Z), or use --bump."
"${PY[@]}" - "$VERSION" <<'EOF' || fail "uv.lock's nitrostack version doesn't match pyproject.toml. Run: python scripts/bump_version.py --help"
import re, sys
lock = open("uv.lock", encoding="utf-8").read()
m = re.search(r'name = "nitrostack"\nversion = "([^"]+)"\nsource = \{ editable = "\." \}', lock)
sys.exit(0 if m and m.group(1) == sys.argv[1] else 1)
EOF
if [ "$DRY_RUN" = 0 ] || [ -z "$BUMP" ]; then
  UPSTREAM="$(git rev-parse -q --verify "origin/$BRANCH" || true)"
  [ "$UPSTREAM" = "$(git rev-parse HEAD)" ] || fail "$BRANCH isn't the same as origin/$BRANCH. Push or pull first, so PyPI gets what the PR merges."
fi
on_pypi "$VERSION" && fail "$VERSION is already on PyPI. Bump the version (--bump) for a new release."
tag_exists "$VERSION" && fail "Tag v$VERSION already exists."
echo "OK: $VERSION isn't on PyPI and isn't tagged."

if [ "$SKIP_TESTS" = 0 ]; then
  step "Running tests"
  "$UV" run --no-project --isolated --quiet --with-editable '.[dev]' \
    python -m pytest -q -p no:cacheprovider tests
fi

step "Building"
rm -rf dist build nitrostack.egg-info
"$UV" build --quiet
WHEEL="dist/nitrostack-$VERSION-py3-none-any.whl"
SDIST="dist/nitrostack-$VERSION.tar.gz"
[ -f "$WHEEL" ] && [ -f "$SDIST" ] || fail "Expected $WHEEL and $SDIST, got: $(ls dist)"
$UVX twine check --strict "$WHEEL" "$SDIST"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "Dry run: built $WHEEL and $SDIST. Nothing was uploaded."
  exit 0
fi

step "Uploading nitrostack $VERSION to PyPI"
if [ "$YES" = 0 ]; then
  read -r -p "Upload nitrostack $VERSION to PyPI? A version can't be uploaded twice. [y/N] " answer
  case "$answer" in y | Y | yes) ;; *) fail "Not uploaded." ;; esac
fi
$UVX twine upload --non-interactive "$WHEEL" "$SDIST"

step "Checking the release on PyPI"
for _ in $(seq 1 30); do
  on_pypi "$VERSION" && break
  sleep 10
done
on_pypi "$VERSION" || fail "PyPI doesn't list $VERSION after 5 minutes. Check https://pypi.org/project/nitrostack/"
VENV="$(mktemp -d)/venv"
"$UV" venv --quiet "$VENV"
installed=""
for _ in $(seq 1 12); do
  if "$UV" pip install --quiet --no-cache --python "$VENV" "nitrostack==$VERSION" 2>/dev/null; then
    installed="$("$VENV/bin/python" -c 'import importlib.metadata as m, nitrostack; print(m.version("nitrostack"))')"
    break
  fi
  sleep 10
done
rm -rf "$(dirname "$VENV")"
[ "$installed" = "$VERSION" ] || fail "Couldn't install and import nitrostack==$VERSION from PyPI."
echo "OK: pip install nitrostack==$VERSION works and imports."

# --- Release PR ---------------------------------------------------------
step "Release PR"
if ! command -v gh >/dev/null; then
  echo "gh not found. Open a PR from $BRANCH to main, labelled 'release'."
else
  PR="$(gh pr list --base main --head "$BRANCH" --json url --jq '.[0].url // empty')"
  if [ -z "$PR" ]; then
    PR="$(gh pr create --base main --head "$BRANCH" --title "chore(release): $VERSION" --label release --body "$(
      cat <<EOF
## Summary
- Bump SDK version to **$VERSION** in \`pyproject.toml\` and \`uv.lock\`.
- $VERSION is already on PyPI (uploaded by \`scripts/release.sh\`), so \`publish.yml\` will skip the upload when this merges.

After merging, tag it: \`scripts/release.sh --tag\`
EOF
    )")"
  fi
  echo "$PR"
fi

echo
echo "Released nitrostack $VERSION. Next: merge the release PR, then run scripts/release.sh --tag"
