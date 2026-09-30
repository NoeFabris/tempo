#!/bin/bash
# Checks the Productive API calls Tempo depends on, with your own token.
# It creates one 0-minute entry, starts and stops a timer on it, prints the results,
# then deletes the entry.
#
#   PRODUCTIVE_TOKEN=… PRODUCTIVE_ORG_ID=… scripts/live-check.sh
set -euo pipefail
: "${PRODUCTIVE_TOKEN:?Set PRODUCTIVE_TOKEN}" "${PRODUCTIVE_ORG_ID:?Set PRODUCTIVE_ORG_ID}"
API="https://api.productive.io/api/v2"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

call() { # method path [body]
  local status
  status=$(curl -sS -o "$TMP/out.json" -w '%{http_code}' -X "$1" "$API/$2" \
    -H "Content-Type: application/vnd.api+json" -H "X-Auth-Token: $PRODUCTIVE_TOKEN" \
    -H "X-Organization-Id: $PRODUCTIVE_ORG_ID" ${3:+--data "$3"})
  echo "── $1 /$2 → HTTP $status" >&2
  cat "$TMP/out.json"
}
py() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

echo "1. Person from organization_memberships"
PERSON=$(call GET "organization_memberships?include=person" | py '
m=d["data"][0]; pid=m["relationships"]["person"]["data"]["id"]
p=[i for i in d.get("included",[]) if i["type"]=="people" and i["id"]==pid]
print(pid); print("   name:", (p[0]["attributes"]["first_name"]+" "+p[0]["attributes"]["last_name"]) if p else "?", file=sys.stderr)')
echo "   person id: $PERSON"

echo "2. Trackable services"
SERVICE=$(call GET "services?filter%5Btrackable_by_person_id%5D=$PERSON&filter%5Btime_tracking_enabled%5D=true&include=deal,deal.project,deal.company&page%5Bsize%5D=5" | py '
print(d["data"][0]["id"]); print("   count on page:", len(d["data"]), "total pages:", d.get("meta",{}).get("total_pages"), file=sys.stderr)
print("   first:", d["data"][0]["attributes"]["name"], file=sys.stderr)')
echo "   using service $SERVICE"

TODAY=$(date +%F)
echo "3. Create a 0-minute entry"
ENTRY=$(call POST "time_entries" "{\"data\":{\"type\":\"time_entries\",\"attributes\":{\"date\":\"$TODAY\",\"time\":0,\"note\":\"Tempo live check (safe to delete)\"},\"relationships\":{\"person\":{\"data\":{\"type\":\"people\",\"id\":\"$PERSON\"}},\"service\":{\"data\":{\"type\":\"services\",\"id\":\"$SERVICE\"}}}}}" | py 'print(d["data"]["id"])')
echo "   entry $ENTRY"

echo "4. Start a timer on the entry"
TIMER=$(call POST "timers" "{\"data\":{\"type\":\"timers\",\"attributes\":{},\"relationships\":{\"time_entry\":{\"data\":{\"type\":\"time_entries\",\"id\":\"$ENTRY\"}}}}}" | py '
print(d["data"]["id"]); print("   attributes:", d["data"]["attributes"], file=sys.stderr)')
echo "   timer $TIMER — waiting 65 s"
sleep 65

echo "5. Entry time while the timer runs (does 'time' include the running minutes?)"
call GET "time_entries/$ENTRY" | py 'a=d["data"]["attributes"]; print("   time:", a.get("time"), "timer_started_at:", a.get("timer_started_at"))'

echo "6. Running timer is listed"
call GET "timers?filter%5Bperson_id%5D=$PERSON&sort=-started_at&page%5Bsize%5D=3" | py '
print("   ", [(t["id"], t["attributes"].get("stopped_at")) for t in d["data"]])'

echo "7. Stop the timer"
call PATCH "timers/$TIMER/stop" | py 'print("   attributes:", d["data"]["attributes"])'
call GET "time_entries/$ENTRY" | py 'print("   entry time after stop:", d["data"]["attributes"].get("time"))'

echo "8. Delete the test entry"
call DELETE "time_entries/$ENTRY" >/dev/null
echo "Done."
