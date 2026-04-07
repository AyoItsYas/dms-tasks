#!/usr/bin/python3

from __future__ import annotations

import sys

import json
from datetime import datetime
from zoneinfo import ZoneInfo
from caldav import get_calendar

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from typing import Any
    from caldav.base_client import CalendarResult


DEBUG = bool(int(sys.argv.pop(-1)))


def debug(*args: Any, **kwargs: Any):
    if DEBUG:
        print(*args, **kwargs)


UTC = ZoneInfo("UTC")


class DateTimeEncoder(json.JSONEncoder):
    def default(self, o: Any):
        if isinstance(o, datetime):
            return o.isoformat()

        return super().default(o)


def __main__(
    CALDAV_URL: str,
    CALDAV_USERNAME: str,
    CALDAV_PASSWORD: str,
    CALDAV_CALENDAR: str,
    *,
    LOCAL_TZ: ZoneInfo = (
        TZ if (TZ := datetime.now().astimezone().tzinfo) else UTC
    ),  # pyright: ignore[reportArgumentType]
) -> dict[str, Any]:
    CALENDAR: CalendarResult = get_calendar(
        url=CALDAV_URL,
        username=CALDAV_USERNAME,
        password=CALDAV_PASSWORD,
        calendar_name=CALDAV_CALENDAR,
    )  # pyright: ignore[reportCallIssue]

    TODO_EVENTS = CALENDAR.search(todo=True, include_completed=True)

    DATA = []
    TODAY = datetime.now(LOCAL_TZ).date()

    total_count, complete_count = 0, 0
    for TODO_EVENT in TODO_EVENTS:
        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()

        if TODO_EVENT_COMPONENT.get("RELATED-TO"):
            continue

        debug(
            TODO_EVENT_COMPONENT.get("SUMMARY"),
            TODO_EVENT_COMPONENT,
        )

        ALL_DAY = False
        DUE = TODO_EVENT_COMPONENT.get("DUE")
        if DUE:
            DUE = DUE.dt.replace(
                tzinfo=(
                    ZoneInfo(TODO_EVENT_COMPONENT.get("TZID"))
                    if TODO_EVENT_COMPONENT.get("TZID")
                    else LOCAL_TZ
                )
            )
        else:
            ALL_DAY = True
            DUE = datetime.today().replace(
                hour=0, minute=0, second=0, microsecond=0, tzinfo=LOCAL_TZ
            )

        DTSTAMP = TODO_EVENT_COMPONENT.get("DTSTAMP").dt.replace(
            tzinfo=(
                ZoneInfo(TODO_EVENT_COMPONENT.get("TZID"))
                if TODO_EVENT_COMPONENT.get("TZID")
                else LOCAL_TZ
            )
        )

        COMPLETE = False
        STATUS = TODO_EVENT_COMPONENT.get("STATUS")

        if DTSTAMP.date() == TODAY:
            total_count += 1
            complete_count += 1

            if STATUS == "COMPLETED":
                COMPLETE = True

        if STATUS == "NEEDS-ACTION" and DUE.date() <= TODAY:
            total_count += 1

        EVENT = {
            "uid": TODO_EVENT_COMPONENT.get("UID"),
            "summary": TODO_EVENT_COMPONENT.get("SUMMARY"),
            "due": DUE,
            "completed": COMPLETE,
            "allDay": ALL_DAY,
        }

        DATA.append(EVENT)

    DATA.sort(key=lambda x: x.get("due"))

    # get the system time and use it to find the current task
    NOW = datetime.now(LOCAL_TZ)
    CURRENT = None

    for TASK in DATA:
        if TASK["due"] and TASK["due"] > NOW:
            CURRENT = TASK
            break

    # group tasks by date

    TASKS_BY_DATE = {}
    for TASK in DATA:
        if TASK["due"]:
            DATE = TASK["due"].date().isoformat()
            if DATE not in TASKS_BY_DATE:
                TASKS_BY_DATE[DATE] = []
            TASKS_BY_DATE[DATE].append(TASK)

    return {
        "currentTask": CURRENT,
        "tasks": list(TASKS_BY_DATE.values()),
        "totalCount": total_count,
        "completeCount": complete_count,
    }


def complete(
    CALDAV_URL: str,
    CALDAV_USERNAME: str,
    CALDAV_PASSWORD: str,
    CALDAV_CALENDAR: str,
):
    pass


if __name__ == "__main__":
    data = {}

    sys.argv.pop(0)  # remove the script name
    MODE = sys.argv.pop(0)  # remove the mode

    MODES = {
        "load": __main__,
        "complete": complete,
    }

    try:
        data = MODES.get(MODE, __main__)(
            *sys.argv
        )  # pyright: ignore[reportArgumentType]
    except Exception as e:
        if DEBUG:
            raise e

    print(
        json.dumps(
            data,
            cls=DateTimeEncoder,
        )
    )
