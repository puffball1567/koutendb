#!/bin/sh

set -eu

classify_flow() {
  event_name=$1
  base_ref=$2
  head_ref=$3
  head_repository=$4
  repository=$5

  if [ "$event_name" != "pull_request" ]; then
    printf '%s\n' full
    return
  fi

  case "$base_ref" in
    devel)
      printf '%s\n' full
      ;;
    main)
      if [ "$head_repository" != "$repository" ]; then
        printf '%s\n' invalid
        return
      fi

      case "$head_ref" in
        devel)
          printf '%s\n' promotion
          ;;
        hotfix/*)
          printf '%s\n' full
          ;;
        *)
          printf '%s\n' invalid
          ;;
      esac
      ;;
    *)
      printf '%s\n' invalid
      ;;
  esac
}

assert_mode() {
  expected=$1
  shift
  actual=$(classify_flow "$@")
  if [ "$actual" != "$expected" ]; then
    printf 'expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

self_test() {
  repository=owner/project

  assert_mode full push "" devel "$repository" "$repository"
  assert_mode full pull_request devel feature/example "$repository" "$repository"
  assert_mode full pull_request devel main "$repository" "$repository"
  assert_mode promotion pull_request main devel "$repository" "$repository"
  assert_mode full pull_request main hotfix/urgent "$repository" "$repository"
  assert_mode invalid pull_request main feature/example "$repository" "$repository"
  assert_mode invalid pull_request main devel fork/project "$repository"
}

verify_promotion() {
  repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
  head_sha=${KOUTEN_HEAD_SHA:?KOUTEN_HEAD_SHA is required}

  devel_sha=$(gh api "/repos/$repository/git/ref/heads/devel" --jq '.object.sha')
  if [ "$head_sha" != "$devel_sha" ]; then
    printf '::error::The pull request head (%s) is not the current devel HEAD (%s).\n' \
      "$head_sha" "$devel_sha"
    exit 1
  fi

  successful_run=$(gh api --method GET "/repos/$repository/actions/workflows/ci.yml/runs" \
    -f branch=devel \
    -f event=push \
    -f status=completed \
    -f head_sha="$head_sha" \
    -f per_page=100 | jq --arg sha "$head_sha" --arg repository "$repository" \
    '[.workflow_runs[] | select(
      .head_sha == $sha and
      .head_branch == "devel" and
      .event == "push" and
      .conclusion == "success" and
      .head_repository.full_name == $repository
    )] | length')

  if [ "$successful_run" -lt 1 ]; then
    printf '::error::No successful devel CI run exists for %s.\n' "$head_sha"
    exit 1
  fi

  printf 'Verified successful devel CI for %s.\n' "$head_sha"
}

command=${1:-}
case "$command" in
  classify)
    shift
    classify_flow "$@"
    ;;
  self-test)
    self_test
    ;;
  verify-promotion)
    verify_promotion
    ;;
  *)
    printf 'usage: %s {classify|self-test|verify-promotion}\n' "$0" >&2
    exit 2
    ;;
esac
