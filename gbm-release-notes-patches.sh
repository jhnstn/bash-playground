#!/usr/bin/env bash

# Adapted from https://betterdev.blog/minimal-safe-bash-script-template/
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-f] -p param_value arg1 [arg2...
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT

  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    tty_reset='\033[0m' tty_red='\033[0;31m' tty_green='\033[0;32m' tty_orange='\033[0;33m' tty_blue='\033[0;34m' tty_purple='\033[0;35m' tty_cyan='\033[0;96m' tty_yellow='\033[1;33m'
  else
    tty_reset='' tty_red='' tty_green='' tty_orange='' tty_blue='' tty_purple='' tty_cyan='' tty_yellow=''
  fi
}
setup_colors

msg() {
  echo >&2 -e "${tty_cyan}${1-}${tty_reset}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "${tty_red}☠️  $msg\n"
  usage
  exit "$code"
}

confirm() {
    read -r -p "$1 (y/n) " -n 1
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        die "Exiting the script...See you later 👋 " 2
    fi
}

parse_params() {
  # default values of variables set from params
  flag=0
  gbm_version=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -d | --debug) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -f | --flag) flag=1 ;; # example flag
    -v | --version) # example named parameter
      gbm_version="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${gbm_version-}" ]] && die "Missing required parameter: version"
  #[[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"

  return 0
}

parse_params "$@"

mkdir release_note_fragments >/dev/null 2>&1 || true
cd release_note_fragments >/dev/null
mkdir -p ./packages/react-native-editor
rm -rf .git

gbm_files_url="https://raw.githubusercontent.com/wordpress-mobile/gutenberg-mobile/a4111e0de5d572bbc29ff78a55abb303d3ccec0e"
gb_files_url="https://raw.githubusercontent.com/WordPress/gutenberg/6b28f0e92be69c71f819cf161dd5c007d32e749d"

gbm_current_version="$(curl -s "${gbm_files_url}/package.json" | jq -r '.version')"
gbm_release_notes_url="${gbm_files_url}/RELEASE-NOTES.txt"
gb_changelog_url="${gb_files_url}/packages/react-native-editor/CHANGELOG.md"

curl -sSL "$gbm_release_notes_url" > RELEASE-NOTES.txt
curl -sSL "$gb_changelog_url" > ./packages/react-native-editor/CHANGELOG.md

git init . --quiet
git add RELEASE-NOTES.txt ./packages/react-native-editor/CHANGELOG.md >/dev/null 2>&1
git commit -m "." >/dev/null 2>&1

skip_updates=false
handle_update_prompt() {
  msg "
  Choose an option:
  Y) Apply proposed updates
  1) Edit RELEASE-NOTES.txt (Gutenberg Mobile)
  2) Edit CHANGELOG.md (Gutenberg)
  *) Manually edit the files later.
  "
  read -r -p "Enter an option:" -n 1
  echo ""
  case "$REPLY" in
    y|Y)
      msg "${tty_green}Generating patches for the release notes and changelog...\n"
      ;;
    1)
      msg "${tty_yellow}Editing the release notes...\n"
      ${EDITOR-vi} RELEASE-NOTES.txt
      show_proposed_updates "true"
      ;;
    2)
      msg "${tty_yellow}Editing the changelog...\n"
      ${EDITOR-vi} ./packages/react-native-editor/CHANGELOG.md
      show_proposed_updates "true"
      ;;
    *)
      msg "${tty_orange}Ok then, manually edit the files later.\n"
      skip_updates=true
      ;;
  esac
}

show_proposed_updates() {
  local skip_unreleased_replacement=${1-}
  local version_regex="/${gbm_current_version//\./\\.}/"

  ## Show proposed RELEASE-NOTES.txt updates
  gcsplit --quiet --prefix='RELEASE-NOTES' --suffix-format='%d.txt' RELEASE-NOTES.txt "$version_regex"  "{*}"
  unreleased_release_notes="$(cat RELEASE-NOTES0.txt)"

  local add_back_unreleased=/dev/null
  if [[ -z "$skip_unreleased_replacement" ]]; then

    echo -e "${unreleased_release_notes/Unreleased/$gbm_version}\n" > RELEASE-NOTES0.txt
    echo -e "Unreleased\n---\n" > RELEASE-NOTES00.txt
    add_back_unreleased=RELEASE-NOTES00.txt
  fi
  cat "$add_back_unreleased" RELEASE-NOTES0.txt RELEASE-NOTES1.txt > RELEASE-NOTES.txt

  msg "\n=> Proposed Release Notes Update for Gutenberg Mobile:\n"
  cat RELEASE-NOTES0.txt

  # spit the changelog by version and remove the leading comments
  cd ./packages/react-native-editor
  gcsplit --quiet --prefix='CHANGELOG' --suffix-format='%d.md' CHANGELOG.md "$version_regex" "{*}"
  if [[ -z "$skip_unreleased_replacement" ]]; then
    subsplit_regex="/##/"
  else
    subsplit_regex="/$gbm_version/"
  fi
  gcsplit --quiet --prefix='CHANGELOG0' --suffix-format='-%d.md' CHANGELOG0.md "$subsplit_regex" "{*}"

  unreleased_changelog=$(cat CHANGELOG0-1.md)

  add_back_unreleased=/dev/null
  if [[ -z "$skip_unreleased_replacement" ]]; then
    echo -e "${unreleased_changelog/Unreleased/$gbm_version}\n" > CHANGELOG0-1.md
    echo -e "## Unreleased\n---\n" > CHANGELOG0-00.txt
    add_back_unreleased=CHANGELOG0-00.txt
  fi
  cat CHANGELOG0-0.md "$add_back_unreleased" CHANGELOG0-1.md CHANGELOG1.md > ./CHANGELOG.md
  msg "\n=> Proposed Changelog Update for Gutenberg:\n"
  cat CHANGELOG0-1.md
  cd - >/dev/null

  handle_update_prompt
}

show_proposed_updates

if [[ "$skip_updates" == "false" ]]; then
  git diff RELEASE-NOTES.txt > ../RELEASE-NOTES.patch || true
  git diff ./packages/react-native-editor/CHANGELOG.md > ../CHANGELOG.patch || true
fi

cd ..
rm -rf release_note_fragments
