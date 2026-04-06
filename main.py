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


DEBUG = bool(int(sys.argv[5]))


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
    DEFAULT_TZ: str = "Asia/Colombo",
) -> dict[str, Any]:
    CALENDAR: CalendarResult = get_calendar(
        url=CALDAV_URL,
        username=CALDAV_USERNAME,
        password=CALDAV_PASSWORD,
        calendar_name=CALDAV_CALENDAR,
    )

    TODO_EVENTS = CALENDAR.search(todo=True, include_completed=True)

    DATA = []

    for TODO_EVENT in TODO_EVENTS:
        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()

        if TODO_EVENT_COMPONENT.get("RELATED-TO"):
            continue

        # debug(TODO_EVENT_COMPONENT)
        # debug(
        #     TODO_EVENT_COMPONENT.get("SUMMARY"),
        #     TODO_EVENT_COMPONENT.get("DUE"),
        #     TODO_EVENT_COMPONENT.get("DUE").dt,
        # )

        ALL_DAY = False
        DUE = TODO_EVENT_COMPONENT.get("DUE")
        if DUE:
            DUE = DUE.dt.replace(
                tzinfo=ZoneInfo(TODO_EVENT_COMPONENT.get("TZID", DEFAULT_TZ))
            )
        else:
            ALL_DAY = True
            DUE = datetime.today().replace(
                hour=0, minute=0, second=0, microsecond=0, tzinfo=ZoneInfo(DEFAULT_TZ)
            )

        EVENT = {
            "uid": TODO_EVENT_COMPONENT.get("UID"),
            "summary": TODO_EVENT_COMPONENT.get("SUMMARY"),
            "due": DUE,
            "completed": True,
            "allDay": ALL_DAY,
        }

        DATA.append(EVENT)

    DATA.sort(key=lambda x: x.get("due"))

    # get the system time and use it to find the current task
    NOW = datetime.now(ZoneInfo(DEFAULT_TZ))
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

    return {"currentTask": CURRENT, "tasks": list(TASKS_BY_DATE.values())}


if __name__ == "__main__":
    data = {}

    try:
        data = __main__(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    except Exception as e:
        if DEBUG:
            raise e

    print(
        json.dumps(
            data,
            cls=DateTimeEncoder,
        )
    )
