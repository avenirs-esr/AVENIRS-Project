#!/usr/bin/env bash
set -euo pipefail

ORG="avenirs-esr"
REPO="AVENIRS-Project"

PROJECT_NUMBERS=(16 3)
ISSUE_TYPES=("User Story" "Epic" "Bug")

APPLY="${APPLY:-false}"

command -v gh >/dev/null || { echo "Erreur: gh CLI manquant"; exit 1; }
command -v jq >/dev/null || { echo "Erreur: jq manquant"; exit 1; }

gh auth status >/dev/null

declare -A PROJECT_IDS

for project_number in "${PROJECT_NUMBERS[@]}"; do
  project_id="$(
    gh api graphql \
      -f org="$ORG" \
      -F number="$project_number" \
      -f query='
        query($org: String!, $number: Int!) {
          organization(login: $org) {
            projectV2(number: $number) {
              id
            }
          }
        }' \
    | jq -r '.data.organization.projectV2.id'
  )"

  [[ -z "$project_id" || "$project_id" == "null" ]] && {
    echo "Erreur: project introuvable: ${ORG}/${project_number}"
    exit 1
  }

  PROJECT_IDS["$project_number"]="$project_id"
done

ISSUES_JSON="$(
  gh api graphql --paginate \
    -f owner="$ORG" \
    -f repo="$REPO" \
    -f query='
      query($owner: String!, $repo: String!, $endCursor: String) {
        repository(owner: $owner, name: $repo) {
          issues(first: 100, after: $endCursor, orderBy: {field: CREATED_AT, direction: ASC}) {
            nodes {
              id
              number
              title
              url
              state
              issueType {
                name
              }
              projectItems(first: 50) {
                nodes {
                  project {
                    number
                    title
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }' \
  | jq -s '[.[].data.repository.issues.nodes[]]'
)"

TYPES_JSON="$(printf '%s\n' "${ISSUE_TYPES[@]}" | jq -R . | jq -s .)"

TARGET_ISSUES="$(
  echo "$ISSUES_JSON" | jq --argjson types "$TYPES_JSON" '
    [
      .[]
      | select(.issueType.name as $t | $types | index($t))
    ]
  '
)"

TMP_MISSING="$(mktemp)"
trap 'rm -f "$TMP_MISSING"' EXIT

TOTAL_TARGET="$(echo "$TARGET_ISSUES" | jq 'length')"

echo "Repo        : ${ORG}/${REPO}"
echo "Mode APPLY  : ${APPLY}"
echo "Issues cibles User Story / Epic / Bug : ${TOTAL_TARGET}"
echo

echo "Répartition par type :"
echo "$TARGET_ISSUES" | jq -r '
  group_by(.issueType.name)
  | map("\(.[0].issueType.name): \(length)")
  | .[]
'
echo

echo "$TARGET_ISSUES" | jq -r '.[] | @base64' | while read -r row; do
  issue="$(echo "$row" | base64 --decode)"

  issue_id="$(echo "$issue" | jq -r '.id')"
  number="$(echo "$issue" | jq -r '.number')"
  title="$(echo "$issue" | jq -r '.title')"
  url="$(echo "$issue" | jq -r '.url')"
  issue_type="$(echo "$issue" | jq -r '.issueType.name')"

  for project_number in "${PROJECT_NUMBERS[@]}"; do

    # Règle spécifique :
    # Les Epics techniques [EPIC][TECH] ne sont pas rattachées au Project PO #3.
    if [[ "$project_number" -eq 3 \
          && "$issue_type" == "Epic" \
          && "$title" =~ ^\[EPIC\]\[TECH\] ]]; then
      continue
    fi

    already_in_project="$(
      echo "$issue" | jq -r --argjson project_number "$project_number" '
        .projectItems.nodes[]
        | select(.project.number == $project_number)
        | .project.number
      ' | head -n 1
    )"

    if [[ "$already_in_project" != "$project_number" ]]; then
      printf "#%s\t%s\tProject #%s\t%s\t%s\n" \
        "$number" "$issue_type" "$project_number" "$title" "$url" >> "$TMP_MISSING"

      if [[ "$APPLY" == "true" ]]; then
        gh api graphql \
          -f projectId="${PROJECT_IDS[$project_number]}" \
          -f contentId="$issue_id" \
          -f query='
            mutation($projectId: ID!, $contentId: ID!) {
              addProjectV2ItemById(input: {
                projectId: $projectId,
                contentId: $contentId
              }) {
                item {
                  id
                }
              }
            }' \
          >/dev/null
      fi
    fi
  done
done

echo "Synthèse des rattachements manquants"
echo

if [[ ! -s "$TMP_MISSING" ]]; then
  echo "Aucune intervention nécessaire."
else
  column -t -s $'\t' "$TMP_MISSING"

  echo
  echo "Nombre d'actions nécessaires : $(wc -l < "$TMP_MISSING" | tr -d ' ')"

  if [[ "$APPLY" != "true" ]]; then
    echo
    echo "DRY-RUN uniquement. Pour appliquer :"
    echo "APPLY=true ./sync-issues-projects.sh"
  else
    echo
    echo "Synchronisation appliquée."
  fi
fi
