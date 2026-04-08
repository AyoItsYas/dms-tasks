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
from datetime import timedelta


DEBUG = bool(int(sys.argv.pop(-1)))


def debug(*args: Any, **kwargs: Any):
    if DEBUG:
        print(*args, **kwargs)


UTC = ZoneInfo("UTC")
LOCAL_TZ = TZ if (TZ := datetime.now().astimezone().tzinfo) else UTC


SUCCESS_PAYLOAD: dict[str, Any] = {"success": True}
FAILED_PAYLOAD: dict[str, Any] = {"success": False}


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
            "priority": TODO_EVENT_COMPONENT.get("PRIORITY", 9),
        }

        DATA.append(EVENT)

    DATA.sort(key=lambda x: x.get("due"))

    # get the system time and use it to find the current task
    NOW = datetime.now(LOCAL_TZ)

    def current_filter(task: dict[str, Any]) -> bool:
        DUE = task.get("due")

        # return False if there is no due date or the task is completed
        if not DUE or task.get("completed"):
            return False

        # return False if the due date is not today
        if DUE.date() != TODAY:
            return False

        # return True if the due date is in the past or now
        if DUE <= NOW:
            return True

        return False

    CURRENT = next(filter(current_filter, DATA), None)

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


def toggle_complete(
    CALDAV_URL: str,
    CALDAV_USERNAME: str,
    CALDAV_PASSWORD: str,
    CALDAV_CALENDAR: str,
    UID: str,
):
    CALENDAR: CalendarResult = get_calendar(
        url=CALDAV_URL,
        username=CALDAV_USERNAME,
        password=CALDAV_PASSWORD,
        calendar_name=CALDAV_CALENDAR,
    )  # pyright: ignore[reportCallIssue]

    TODO_EVENTS = CALENDAR.search(todo=True, include_completed=True, uid=UID)

    debug("Completing task with UID:", UID)

    for TODO_EVENT in TODO_EVENTS:
        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()
        debug(TODO_EVENT_COMPONENT.get("SUMMARY"), TODO_EVENT_COMPONENT)

        RRULE = TODO_EVENT_COMPONENT.get("RRULE")

        COMPLETE = TODO_EVENT_COMPONENT.get("STATUS") == "COMPLETED"

        with TODO_EVENT.edit_icalendar_component() as COMPONENT:
            if COMPLETE:
                COMPONENT["STATUS"] = "NEEDS-ACTION"
                del COMPONENT["COMPLETED"]
            else:
                if RRULE:
                    if RRULE.get("FREQ") == ["DAILY"]:
                        due_date = COMPONENT['DUE'].dt
                        COMPONENT['DUE'].dt = due_date + timedelta(days=1)
                        COMPONENT["DTSTAMP"] = (
                            datetime.now(UTC).replace(microsecond=0).strftime("%Y%m%dT%H%M%SZ")
                        )
                    else:
                        raise NotImplementedError("Not implemented toggle complete for non-daily repeating tasks")
                else:
                    COMPONENT["STATUS"] = "COMPLETED"
                    COMPONENT["COMPLETED"] = (
                        datetime.now(UTC).replace(microsecond=0).strftime("%Y%m%dT%H%M%SZ")
                    )

        TODO_EVENT.save()

        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()
        debug(TODO_EVENT_COMPONENT.get("SUMMARY"), TODO_EVENT_COMPONENT)

    return SUCCESS_PAYLOAD


if __name__ == "__main__":
    data = {}

    sys.argv.pop(0)  # remove the script name
    MODE = sys.argv.pop(0)  # remove the mode

    MODES = {
        "load": __main__,
        "toggle_complete": toggle_complete,
    }

    data = FAILED_PAYLOAD
    try:
        data = MODES.get(MODE, __main__)(
            *sys.argv
        )  # pyright: ignore[reportArgumentType]
        data = {**SUCCESS_PAYLOAD, "data": data}
    except Exception as e:
        if DEBUG:
            raise e
        data["message"] = str(e)

    print(
        json.dumps(
            data,
            cls=DateTimeEncoder,
        )
    )
