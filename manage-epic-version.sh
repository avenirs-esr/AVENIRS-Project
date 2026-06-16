#!/usr/bin/env bash
set -euo pipefail

ORG="avenirs-esr"
REPO="AVENIRS-Project"
PROJECT_NUMBERS=(16 3)

STATE="${STATE:-OPEN}"              # OPEN, CLOSED, ALL
INCLUDE_TECH="${INCLUDE_TECH:-false}"
SOURCE_VERSION="${SOURCE_VERSION:-ALL}"
LIST_SORT="${LIST_SORT:-version}"   # version ou title

MODE="${1:-}"
ARG1="${2:-}"
ARG2="${3:-}"

command -v gh >/dev/null || { echo "Erreur: gh CLI manquant"; exit 1; }
command -v jq >/dev/null || { echo "Erreur: jq manquant"; exit 1; }
gh auth status >/dev/null

usage() {
  cat <<EOF
Usage:
  $0 --list
  $0 --duplicate <numero_issue> <version_milestone>
  $0 --duplicate-all <version_milestone>

Options via variables:
  STATE=OPEN|CLOSED|ALL              défaut: OPEN
  INCLUDE_TECH=true|false            défaut: false
  SOURCE_VERSION=MVP|V1|V2|ALL       défaut: ALL
  LIST_SORT=version|title            défaut: version

Exemples:
  $0 --list
  LIST_SORT=title $0 --list
  $0 --duplicate 302 V1
  SOURCE_VERSION=MVP $0 --duplicate-all V1
  STATE=ALL INCLUDE_TECH=true $0 --list
EOF
}

if [[ -z "$MODE" ]]; then
  usage
  exit 1
fi

get_repo_data() {
  gh api graphql --paginate \
    -f owner="$ORG" \
    -f repo="$REPO" \
    -f query='
      query($owner: String!, $repo: String!, $endCursor: String) {
        repository(owner: $owner, name: $repo) {
          id
          milestones(first: 100, states: OPEN) {
            nodes { id title }
          }
          issues(first: 100, after: $endCursor, orderBy: {field: CREATED_AT, direction: ASC}) {
            nodes {
              id
              number
              title
              body
              url
              state
              issueType { id name }
              milestone { id title }
              labels(first: 100) { nodes { name } }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }' \
  | jq -s '{
      repositoryId: .[0].data.repository.id,
      milestones: .[0].data.repository.milestones.nodes,
      issues: [.[].data.repository.issues.nodes[]]
    }'
}

normalize_title() {
  local title="$1"

  echo "$title" \
    | sed -E 's/^\[EPIC\]\[(MVP|TECH|V[0-9]+)\][[:space:]]+//' \
    | sed -E 's/^\[EPIC\]:[[:space:]]+//' \
    | sed -E 's/^\[EPIC\][[:space:]]+//'
}

make_target_title() {
  local source_title="$1"
  local target_version="$2"
  local rest

  rest="$(normalize_title "$source_title")"
  echo "[EPIC][${target_version}] ${rest}"
}

get_version_from_title() {
  local title="$1"

  if [[ "$title" =~ ^\[EPIC\]\[([^]]+)\] ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

fetch_project_id() {
  local project_number="$1"

  gh api graphql \
    -f org="$ORG" \
    -F number="$project_number" \
    -f query='
      query($org: String!, $number: Int!) {
        organization(login: $org) {
          projectV2(number: $number) { id }
        }
      }' \
  | jq -r '.data.organization.projectV2.id'
}

create_duplicate() {
  local data="$1"
  local issue="$2"
  local target_version="$3"
  local ask_confirm="${4:-true}"

  local repo_id milestone_id source_number source_title source_body source_url
  local issue_type_id issue_type_name labels new_title new_body create_result
  local new_issue_id new_issue_number new_issue_url

  repo_id="$(echo "$data" | jq -r '.repositoryId')"

  milestone_id="$(
    echo "$data" | jq -r --arg version "$target_version" '
      .milestones[] | select(.title == $version) | .id
    '
  )"

  if [[ -z "$milestone_id" || "$milestone_id" == "null" ]]; then
    echo "Erreur: milestone ouverte introuvable: ${target_version}"
    exit 1
  fi

  source_number="$(echo "$issue" | jq -r '.number')"
  source_title="$(echo "$issue" | jq -r '.title')"
  source_body="$(echo "$issue" | jq -r '.body // ""')"
  source_url="$(echo "$issue" | jq -r '.url')"
  issue_type_id="$(echo "$issue" | jq -r '.issueType.id // empty')"
  issue_type_name="$(echo "$issue" | jq -r '.issueType.name // "aucun"')"
  labels="$(echo "$issue" | jq -r '[.labels.nodes[].name] | join(",")')"
  new_title="$(make_target_title "$source_title" "$target_version")"

  new_body="$(cat <<EOF
${source_body}

---

## Origine

Issue dupliquée depuis ${source_url}

Version cible : ${target_version}
EOF
)"

  echo "Source : #${source_number} ${source_title}"
  echo "Cible  : ${new_title}"
  echo "Type   : ${issue_type_name}"
  echo "Labels : ${labels:-aucun}"
  echo

  if [[ "$ask_confirm" == "true" ]]; then
    read -r -p "Créer cette nouvelle issue ? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Annulé."
      return 0
    fi
  fi

  create_result="$(
    gh api graphql \
      -f repositoryId="$repo_id" \
      -f title="$new_title" \
      -f body="$new_body" \
      -f milestoneId="$milestone_id" \
      -f issueTypeId="$issue_type_id" \
      -f query='
        mutation($repositoryId: ID!, $title: String!, $body: String!, $milestoneId: ID!, $issueTypeId: ID!) {
          createIssue(input: {
            repositoryId: $repositoryId,
            title: $title,
            body: $body,
            milestoneId: $milestoneId,
            issueTypeId: $issueTypeId
          }) {
            issue { id number url }
          }
        }'
  )"

  new_issue_id="$(echo "$create_result" | jq -r '.data.createIssue.issue.id')"
  new_issue_number="$(echo "$create_result" | jq -r '.data.createIssue.issue.number')"
  new_issue_url="$(echo "$create_result" | jq -r '.data.createIssue.issue.url')"

  if [[ -n "$labels" ]]; then
    gh issue edit "$new_issue_number" \
      --repo "${ORG}/${REPO}" \
      --add-label "$labels"
  fi

  for project_number in "${PROJECT_NUMBERS[@]}"; do
    project_id="$(fetch_project_id "$project_number")"

    gh api graphql \
      -f projectId="$project_id" \
      -f contentId="$new_issue_id" \
      -f query='
        mutation($projectId: ID!, $contentId: ID!) {
          addProjectV2ItemById(input: {
            projectId: $projectId,
            contentId: $contentId
          }) {
            item { id }
          }
        }' >/dev/null
  done

  echo "Issue créée : #${new_issue_number}"
  echo "$new_issue_url"
  echo
}

DATA="$(get_repo_data)"

EPICS="$(
  echo "$DATA" | jq --arg state "$STATE" '
    [
      .issues[]
      | select(.issueType.name == "Epic")
      | if $state == "ALL" then . else select(.state == $state) end
    ]
  '
)"

if [[ "$INCLUDE_TECH" != "true" ]]; then
  EPICS="$(echo "$EPICS" | jq '[.[] | select(.title | startswith("[EPIC][TECH]") | not)]')"
fi

case "$MODE" in
  --list)
    TMP_LIST="$(mktemp)"
    trap 'rm -f "$TMP_LIST" "${TMP_LIST}.sorted"' EXIT

    echo "$EPICS" | jq -r '.[] | @base64' | while read -r row; do
      epic="$(echo "$row" | base64 --decode)"

      number="$(echo "$epic" | jq -r '.number')"
      state="$(echo "$epic" | jq -r '.state')"
      milestone="$(echo "$epic" | jq -r '.milestone.title // "sans milestone"')"
      title="$(echo "$epic" | jq -r '.title')"
      url="$(echo "$epic" | jq -r '.url')"

      version="$(get_version_from_title "$title")"
      base_title="$(normalize_title "$title")"

      [[ -z "$version" ]] && version="$milestone"

      printf "%s\t%s\t#%s\t%s\t%s\t%s\t%s\n" \
        "$version" "$base_title" "$number" "$state" "$milestone" "$title" "$url" >> "$TMP_LIST"
    done

    if [[ "$LIST_SORT" == "title" ]]; then
      sort -f -t $'\t' -k2,2 -k1,1 "$TMP_LIST" > "${TMP_LIST}.sorted"
    else
      sort -f -t $'\t' -k1,1 -k2,2 "$TMP_LIST" > "${TMP_LIST}.sorted"
    fi

    echo "Tri LIST_SORT=${LIST_SORT}"
    echo
    cut -f3- "${TMP_LIST}.sorted" | column -t -s $'\t'
    ;;

  --duplicate)
    issue_number="$ARG1"
    target_version="$ARG2"

    if [[ -z "$issue_number" || -z "$target_version" ]]; then
      usage
      exit 1
    fi

    ISSUE="$(echo "$EPICS" | jq --argjson n "$issue_number" '.[] | select(.number == $n)')"

    if [[ -z "$ISSUE" ]]; then
      echo "Erreur: Epic #${issue_number} introuvable dans le périmètre STATE=${STATE}, INCLUDE_TECH=${INCLUDE_TECH}"
      exit 1
    fi

    create_duplicate "$DATA" "$ISSUE" "$target_version" "true"
    ;;

  --duplicate-all)
    target_version="$ARG1"

    if [[ -z "$target_version" ]]; then
      usage
      exit 1
    fi

    echo "Recherche des Epics à dupliquer vers ${target_version}..."
    echo "STATE=${STATE}, INCLUDE_TECH=${INCLUDE_TECH}, SOURCE_VERSION=${SOURCE_VERSION}"
    echo

    TMP_PLAN="$(mktemp)"
    trap 'rm -f "$TMP_PLAN" "${TMP_PLAN}.sorted"' EXIT

    echo "$EPICS" | jq -r '.[] | @base64' | while read -r row; do
      issue="$(echo "$row" | base64 --decode)"

      title="$(echo "$issue" | jq -r '.title')"
      number="$(echo "$issue" | jq -r '.number')"
      source_version="$(get_version_from_title "$title")"
      base_title="$(normalize_title "$title")"
      target_title="[EPIC][${target_version}] ${base_title}"

      if [[ "$source_version" == "$target_version" ]]; then
        continue
      fi

      if [[ "$SOURCE_VERSION" != "ALL" && "$source_version" != "$SOURCE_VERSION" ]]; then
        continue
      fi

      exists="$(
        echo "$EPICS" | jq -r --arg t "$target_title" '
          [.[] | select(.title == $t)] | length
        '
      )"

      if [[ "$exists" -gt 0 ]]; then
        continue
      fi

      already_planned="$(cut -f4 "$TMP_PLAN" 2>/dev/null | grep -Fx "$target_title" || true)"
      if [[ -n "$already_planned" ]]; then
        continue
      fi

      printf "%s\t%s\t%s\t%s\n" \
        "$base_title" \
        "$number" \
        "$title" \
        "$target_title" >> "$TMP_PLAN"
    done

    if [[ ! -s "$TMP_PLAN" ]]; then
      echo "Aucune Epic à dupliquer."
      exit 0
    fi

    sort -f -t $'\t' -k1,1 "$TMP_PLAN" > "${TMP_PLAN}.sorted"
    mv "${TMP_PLAN}.sorted" "$TMP_PLAN"

    echo "Plan de duplication :"
    cut -f2- "$TMP_PLAN" | column -t -s $'\t'
    echo
    echo "Nombre d'Epics à créer : $(wc -l < "$TMP_PLAN" | tr -d ' ')"
    echo

    read -r -p "Dupliquer toutes ces Epics vers ${target_version} ? [y/N] " confirm_all
    if [[ ! "$confirm_all" =~ ^[Yy]$ ]]; then
      echo "Annulé."
      exit 0
    fi

    while IFS=$'\t' read -r base_title issue_number old_title new_title; do
      ISSUE="$(echo "$EPICS" | jq --argjson n "$issue_number" '.[] | select(.number == $n)')"
      create_duplicate "$DATA" "$ISSUE" "$target_version" "false"
    done < "$TMP_PLAN"
    ;;

  *)
    usage
    exit 1
    ;;
esac