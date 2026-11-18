#!/bin/bash
# wp-cron-check.sh: exit 1 if any WP-Cron event is more than MAX_LATE seconds overdue.
# Usage: wp-cron-check.sh [max_late_seconds]   (default 900)
WP="/usr/bin/php /usr/local/bin/wp"       # absolute paths: cron has a minimal PATH
SITE=/var/www/example.com/public
MAX_LATE=${1:-900}

now=$(date +%s)
late=$($WP cron event list --path="$SITE" --fields=hook,time --format=csv \
  | tail -n +2 \
  | awk -F, -v now="$now" -v max="$MAX_LATE" \
      '($2 + max) < now { print $1 " is " (now - $2) "s overdue" }')

if [ -n "$late" ]; then
  echo "$late"
  exit 1
fi
echo "OK: no events more than ${MAX_LATE}s overdue"
