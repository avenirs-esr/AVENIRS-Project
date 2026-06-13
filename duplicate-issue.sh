#!/usr/bin/env bash
set -euo pipefail

ORG="avenirs-esr"
REPO="AVENIRS-Project"

SOURCE_ISSUE_NUMBER="${1:-}"
TARGET_VERSION="${2:-}"

PROJECT_NUMBERS=(16 3)

if [[ -z "$SOURCE_ISSUE_NUMBER" || -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <numero_issue_source> <version_milestone>"
  echo "Exemple: $0 302 V1"
  exit 1
fi

command -v gh >/dev/null || { echo "Erreur: gh CLI manquant"; exit 1; }
command -v jq >/dev/null || { echo "Erreur: jq manquant"; exit 1; }

gh auth status >/dev/null

DATA="$(
  gh api graphql \
    -f owner="$ORG" \
    -f repo="$REPO" \
    -F number="$SOURCE_ISSUE_NUMBER" \
    -f query='
      query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          id
          milestones(first: 100, states: OPEN) {
            nodes {
              id
              title
            }
          }
          issue(number: $number) {
            number
            title
            body
            url
            issueType {
              id
              name
            }
            labels(first: 100) {
              nodes {
                name
              }
            }
          }
        }
      }'
)"

REPO_ID="$(echo "$DATA" | jq -r '.data.repository.id')"
ISSUE="$(echo "$DATA" | jq '.data.repository.issue')"

if [[ "$ISSUE" == "null" ]]; then
  echo "Erreur: issue source introuvable: #${SOURCE_ISSUE_NUMBER}"
  exit 1
fi

MILESTONE_ID="$(
  echo "$DATA" | jq -r --arg version "$TARGET_VERSION" '
    .data.repository.milestones.nodes[]
    | select(.title == $version)
    | .id
  '
)"

if [[ -z "$MILESTONE_ID" || "$MILESTONE_ID" == "null" ]]; then
  echo "Erreur: milestone ouverte introuvable: ${TARGET_VERSION}"
  exit 1
fi

SOURCE_TITLE="$(echo "$ISSUE" | jq -r '.title')"
SOURCE_BODY="$(echo "$ISSUE" | jq -r '.body // ""')"
SOURCE_URL="$(echo "$ISSUE" | jq -r '.url')"
ISSUE_TYPE_ID="$(echo "$ISSUE" | jq -r '.issueType.id // empty')"
ISSUE_TYPE_NAME="$(echo "$ISSUE" | jq -r '.issueType.name // "aucun"')"
LABELS="$(echo "$ISSUE" | jq -r '[.labels.nodes[].name] | join(",")')"

if [[ "$SOURCE_TITLE" =~ ^\[EPIC\]\[(MVP|TECH|V[0-9]+)\][[:space:]] ]]; then
  TITLE_REST="$(echo "$SOURCE_TITLE" | sed -E 's/^\[EPIC\]\[(MVP|TECH|V[0-9]+)\][[:space:]]+//')"
  NEW_TITLE="[EPIC][${TARGET_VERSION}] ${TITLE_REST}"
elif [[ "$SOURCE_TITLE" =~ ^\[EPIC\][[:space:]] ]]; then
  TITLE_REST="${SOURCE_TITLE#"[EPIC] "}"
  NEW_TITLE="[EPIC][${TARGET_VERSION}] ${TITLE_REST}"
else
  NEW_TITLE="[${TARGET_VERSION}] ${SOURCE_TITLE}"
fi

NEW_BODY="$(
cat <<EOF
${SOURCE_BODY}

---

## Origine

Issue dupliquée depuis ${SOURCE_URL}

Version cible : ${TARGET_VERSION}
EOF
)"

echo "Duplication d'issue"
echo
echo "Source issue : #${SOURCE_ISSUE_NUMBER}"
echo "Avant        : ${SOURCE_TITLE}"
echo "Après        : ${NEW_TITLE}"
echo "Type         : ${ISSUE_TYPE_NAME}"
echo "Milestone    : ${TARGET_VERSION}"
echo "Labels       : ${LABELS:-aucun}"
echo "Projects     : ${PROJECT_NUMBERS[*]}"
echo

read -r -p "Créer cette nouvelle issue ? [y/N] " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Annulé."
  exit 0
fi

if [[ -n "$ISSUE_TYPE_ID" ]]; then
  CREATE_RESULT="$(
    gh api graphql \
      -f repositoryId="$REPO_ID" \
      -f title="$NEW_TITLE" \
      -f body="$NEW_BODY" \
      -f issueTypeId="$ISSUE_TYPE_ID" \
      -f milestoneId="$MILESTONE_ID" \
      -f query='
        mutation($repositoryId: ID!, $title: String!, $body: String!, $issueTypeId: ID!, $milestoneId: ID!) {
          createIssue(input: {
            repositoryId: $repositoryId,
            title: $title,
            body: $body,
            issueTypeId: $issueTypeId,
            milestoneId: $milestoneId
          }) {
            issue {
              id
              number
              url
            }
          }
        }'
  )"
else
  CREATE_RESULT="$(
    gh api graphql \
      -f repositoryId="$REPO_ID" \
      -f title="$NEW_TITLE" \
      -f body="$NEW_BODY" \
      -f milestoneId="$MILESTONE_ID" \
      -f query='
        mutation($repositoryId: ID!, $title: String!, $body: String!, $milestoneId: ID!) {
          createIssue(input: {
            repositoryId: $repositoryId,
            title: $title,
            body: $body,
            milestoneId: $milestoneId
          }) {
            issue {
              id
              number
              url
            }
          }
        }'
  )"
fi

NEW_ISSUE_ID="$(echo "$CREATE_RESULT" | jq -r '.data.createIssue.issue.id')"
NEW_ISSUE_NUMBER="$(echo "$CREATE_RESULT" | jq -r '.data.createIssue.issue.number')"
NEW_ISSUE_URL="$(echo "$CREATE_RESULT" | jq -r '.data.createIssue.issue.url')"

if [[ -n "$LABELS" ]]; then
  gh issue edit "$NEW_ISSUE_NUMBER" \
    --repo "${ORG}/${REPO}" \
    --add-label "$LABELS"
fi

for project_number in "${PROJECT_NUMBERS[@]}"; do
  PROJECT_ID="$(
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

  gh api graphql \
    -f projectId="$PROJECT_ID" \
    -f contentId="$NEW_ISSUE_ID" \
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
done

echo
echo "Issue créée : #${NEW_ISSUE_NUMBER}"
echo "$NEW_ISSUE_URL"
echo "Rattachement aux Projects effectué."
