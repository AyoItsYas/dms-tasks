#!/bin/bash

JQ=1
BAT=1

DEBUG=1

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "No .env file found. Please create one with the necessary environment variables."
    exit 1
fi

OUTPUT=$(./main.py load "$CALDAV_URL" "$CALDAV_USERNAME" "$CALDAV_PASSWORD" "$CALDAV_CALENDAR" "$DEBUG")


if [ "$DEBUG" -eq 0 ] && [ "$JQ" -eq 1 ] && command -v jq &> /dev/null; then
    OUTPUT=$(echo "$LOAD_OUT" | jq .)

    if [ "$BAT" -eq 1 ] && command -v bat &> /dev/null; then
        echo "$OUTPUT" | bat --paging=never --language=json
    else
        echo "$OUTPUT"
    fi
else
    if [ "$BAT" -eq 1 ] && command -v bat &> /dev/null; then
        echo "$OUTPUT" | bat --paging=never
    else
        echo "$OUTPUT"
    fi
fi

