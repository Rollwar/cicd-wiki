#!/usr/bin/env bash
# scripts/notify.sh — sends a rich Slack notification.
# Usage:
#   notify.sh "<title>" "<subtitle>" "<commit_sha>" "<color_hex>"
# Requires env: SLACK_WEBHOOK_URL
set -euo pipefail

TITLE="${1:-Wiki.js pipeline event}"
SUBTITLE="${2:--}"
SHA="${3:--}"
COLOR="${4:-#36a64f}"
SHORT_SHA=$(echo -n "$SHA" | cut -c1-12)

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "[notify] SLACK_WEBHOOK_URL not set — skipping Slack notification"
  exit 0
fi

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Rollwar/cicd-wikijs}/actions/runs/${GITHUB_RUN_ID:-0}"
BRANCH="${GITHUB_REF_NAME:-main}"
ACTOR="${GITHUB_ACTOR:-ci-bot}"

PAYLOAD=$(cat <<JSON
{
  "attachments": [{
    "color": "$COLOR",
    "blocks": [
      { "type": "header", "text": { "type": "plain_text", "text": "$TITLE" } },
      { "type": "section", "fields": [
        { "type": "mrkdwn", "text": "*Detail:*\n$SUBTITLE" },
        { "type": "mrkdwn", "text": "*Branch:*\n$BRANCH" },
        { "type": "mrkdwn", "text": "*Commit:*\n\`$SHORT_SHA\`" },
        { "type": "mrkdwn", "text": "*Author:*\n$ACTOR" }
      ]},
      { "type": "context", "elements": [
        { "type": "mrkdwn", "text": "<$RUN_URL|View pipeline run>" }
      ]}
    ]
  }]
}
JSON
)

curl -sS -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$SLACK_WEBHOOK_URL" \
  && echo "[notify] Slack notification sent"
