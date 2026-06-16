#!/usr/bin/env bash
set -euo pipefail

ORG="avenirs-esr"
REPO="AVENIRS-Project"

# Valeurs possibles : OPEN, CLOSED, ALL
STATE="${STATE:-OPEN}"

# Par défaut, on ignore les EPIC techniques.
EXCLUDE_TECH="${EXCLUDE_TECH:-true}"

# Par défaut, on contrôle aussi les US associées.
CHECK_US="${CHECK_US:-true}"

command -v gh >/dev/null || { echo "Erreur: gh CLI manquant"; exit 1; }
command -v jq >/dev/null || { echo "Erreur: jq manquant"; exit 1; }

gh auth status >/dev/null

echo "Repo         : ${ORG}/${REPO}"
echo "State        : ${STATE}"
echo "Exclude TECH : ${EXCLUDE_TECH}"
echo "Check US     : ${CHECK_US}"
echo

ISSUES_JSON="$(
  gh api graphql --paginate \
    -f owner="$ORG" \
    -f repo="$REPO" \
    -f query='
      query($owner: String!, $repo: String!, $endCursor: String) {
        repository(owner: $owner, name: $repo) {
          issues(first: 100, after: $endCursor, orderBy: {field: CREATED_AT, direction: ASC}) {
            nodes {
              number
              title
              url
              state
              issueType {
                name
              }
              milestone {
                title
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

if [[ "$STATE" == "ALL" ]]; then
  EPICS="$(
    echo "$ISSUES_JSON" | jq '
      [
        .[]
        | select(.issueType.name == "Epic")
      ]
    '
  )"
else
  EPICS="$(
    echo "$ISSUES_JSON" | jq --arg state "$STATE" '
      [
        .[]
        | select(.state == $state)
        | select(.issueType.name == "Epic")
      ]
    '
  )"
fi

TMP_REPORT="$(mktemp)"
trap 'rm -f "$TMP_REPORT"' EXIT

TOTAL="$(echo "$EPICS" | jq 'length')"

echo "Epics analysées : ${TOTAL}"
echo

echo "$EPICS" | jq -r '.[] | @base64' | while read -r row; do
  epic="$(echo "$row" | base64 --decode)"

  epic_number="$(echo "$epic" | jq -r '.number')"
  epic_title="$(echo "$epic" | jq -r '.title')"
  epic_url="$(echo "$epic" | jq -r '.url')"
  epic_milestone="$(echo "$epic" | jq -r '.milestone.title // empty')"

  if [[ "$EXCLUDE_TECH" == "true" && "$epic_title" =~ ^\[EPIC\]\[TECH\] ]]; then
    continue
  fi

  if [[ -z "$epic_milestone" ]]; then
    printf "#%s\t%s\t%s\t%s\n" \
      "$epic_number" \
      "EPIC_MILESTONE_MANQUANTE" \
      "$epic_title" \
      "$epic_url" >> "$TMP_REPORT"
    continue
  fi

  expected_prefix="[EPIC][${epic_milestone}]"

  if [[ "$epic_title" != "$expected_prefix"* ]]; then
    printf "#%s\t%s\tMilestone=%s | Titre=%s\t%s\n" \
      "$epic_number" \
      "EPIC_TITRE_NON_CONFORME" \
      "$epic_milestone" \
      "$epic_title" \
      "$epic_url" >> "$TMP_REPORT"
  fi

  if [[ "$CHECK_US" != "true" ]]; then
    continue
  fi

  SUB_ISSUES="$(
    gh api \
      -H "Accept: application/vnd.github+json" \
      "/repos/${ORG}/${REPO}/issues/${epic_number}/sub_issues" \
    | jq '
      [
        .[]
        | select(.pull_request == null)
        | {
            number,
            title,
            html_url,
            state,
            milestone: (.milestone.title // ""),
            labels: [.labels[].name]
          }
      ]
    '
  )"

  echo "$SUB_ISSUES" | jq -r '.[] | @base64' | while read -r sub_row; do
    us="$(echo "$sub_row" | base64 --decode)"

    us_number="$(echo "$us" | jq -r '.number')"
    us_title="$(echo "$us" | jq -r '.title')"
    us_url="$(echo "$us" | jq -r '.html_url')"
    us_state="$(echo "$us" | jq -r '.state | ascii_upcase')"
    us_milestone="$(echo "$us" | jq -r '.milestone // empty')"

    if [[ "$STATE" != "ALL" && "$us_state" != "$STATE" ]]; then
      continue
    fi

    if [[ -z "$us_milestone" ]]; then
      printf "#%s\t%s\tEpic #%s milestone=%s | US sans milestone | %s\t%s\n" \
        "$us_number" \
        "US_MILESTONE_MANQUANTE" \
        "$epic_number" \
        "$epic_milestone" \
        "$us_title" \
        "$us_url" >> "$TMP_REPORT"
      continue
    fi

    if [[ "$us_milestone" != "$epic_milestone" ]]; then
      printf "#%s\t%s\tEpic #%s milestone=%s | US milestone=%s | %s\t%s\n" \
        "$us_number" \
        "US_MILESTONE_DIFFERENTE" \
        "$epic_number" \
        "$epic_milestone" \
        "$us_milestone" \
        "$us_title" \
        "$us_url" >> "$TMP_REPORT"
    fi
  done
done

echo "Synthèse des anomalies"
echo

if [[ ! -s "$TMP_REPORT" ]]; then
  echo "Aucune anomalie détectée."
else
  column -t -s $'\t' "$TMP_REPORT"
  echo
  echo "Nombre d'anomalies : $(wc -l < "$TMP_REPORT" | tr -d ' ')"
fi
