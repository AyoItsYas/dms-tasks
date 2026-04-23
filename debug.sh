#!/bin/bash

SSL=0

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "No .env file found. Please create one with the necessary environment variables."
    exit 1
fi

./main.py load "$CALDAV_URL" "$CALDAV_USERNAME" "$CALDAV_PASSWORD" "$CALDAV_CALENDAR" "" "$SSL" "1"
