#!/usr/bin/python3

from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timedelta
from typing import TYPE_CHECKING
from zoneinfo import ZoneInfo

import urllib3

from caldav import get_calendar

if TYPE_CHECKING:
    from typing import Any

    from caldav.base_client import CalendarResult


DEBUG = bool(int(sys.argv.pop(-1)))
SSL_VERIFY = bool(int(sys.argv.pop(-1)))

if not SSL_VERIFY:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Capture caldav library errors so they appear in JSON output
_caldav_errors: list[str] = []


class _CaldavErrorHandler(logging.Handler):
    def emit(self, record: logging.LogRecord):
        _caldav_errors.append(record.getMessage())


logging.getLogger("caldav").addHandler(_CaldavErrorHandler())


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
    CALDAV_CALENDARS: str,
    PRIORITY: str | None,
) -> dict[str, Any]:
    DATA = []
    NOW = datetime.now(LOCAL_TZ)
    TODAY = datetime.now(LOCAL_TZ).date()

    try:
        PRIORITY = int(PRIORITY)
    except Exception as _:
        PRIORITY = None

    total_count, complete_count = 0, 0

    for CALDAV_CALENDAR in CALDAV_CALENDARS.split(","):
        _caldav_errors.clear()
        CALENDAR: CalendarResult = get_calendar(
            url=CALDAV_URL,
            username=CALDAV_USERNAME,
            password=CALDAV_PASSWORD,
            calendar_name=CALDAV_CALENDAR,
            ssl_verify_cert=SSL_VERIFY,
        )  # pyright: ignore[reportCallIssue]

        if not CALENDAR:
            detail = _caldav_errors[-1] if _caldav_errors else "check URL, credentials, and calendar name"
            raise ValueError(
                f"Calendar '{CALDAV_CALENDAR}' not found on {CALDAV_URL}: {detail}"
            )

        TODO_EVENTS = CALENDAR.search(
            todo=True,
            include_completed=True,
        )

        for TODO_EVENT in TODO_EVENTS:
            TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()

            TASK_PRIORITY = TODO_EVENT_COMPONENT.get("PRIORITY", 9)
            if PRIORITY is not None and PRIORITY >= 0 and TASK_PRIORITY != PRIORITY:
                continue

            debug(
                TODO_EVENT_COMPONENT.get("SUMMARY"),
                TODO_EVENT_COMPONENT,
            )

            ALL_DAY = False
            DUE = TODO_EVENT_COMPONENT.get("DUE", False)

            try:
                DUE.dt.hour
            except AttributeError:
                ALL_DAY = True

            if DUE and not ALL_DAY:
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

            DTSTAMP_RAW = TODO_EVENT_COMPONENT.get("DTSTAMP")
            if DTSTAMP_RAW:
                DTSTAMP = DTSTAMP_RAW.dt.replace(
                    tzinfo=(
                        ZoneInfo(TODO_EVENT_COMPONENT.get("TZID"))
                        if TODO_EVENT_COMPONENT.get("TZID")
                        else LOCAL_TZ
                    )
                )
            else:
                DTSTAMP = datetime.now(LOCAL_TZ)

            COMPLETE = False
            STATUS = TODO_EVENT_COMPONENT.get("STATUS")

            if DTSTAMP.date() == TODAY:
                total_count += 1
                complete_count += 1

                if STATUS == "COMPLETED":
                    COMPLETE = True

            if STATUS == "COMPLETED" and ALL_DAY:
                COMPLETE = True
                complete_count += 1
                total_count += 1

            if STATUS == "NEEDS-ACTION" and DUE.date() <= TODAY:
                total_count += 1

            EVENT = {
                "uid": TODO_EVENT_COMPONENT.get("UID"),
                "summary": TODO_EVENT_COMPONENT.get("SUMMARY"),
                "due": DUE,
                "completed": COMPLETE,
                "allDay": ALL_DAY,
                "priority": TODO_EVENT_COMPONENT.get("PRIORITY", 9),
                "calendar": CALDAV_CALENDAR,
                # "raw": TODO_EVENT.get_icalendar_instance().to_ical().decode(),
            }

            DATA.append(EVENT)

        DATA.sort(key=lambda x: (x.get("completed"), x.get("due")))

    def current_filter(task: dict[str, Any]) -> bool:
        DUE = task.get("due")

        # return False if there is no due date or the task is completed
        if not DUE or task.get("completed"):
            return False

        if task.get("allDay"):
            return False

        # return False if the due date is not today
        if DUE.date() != TODAY:
            return False

        # return True if the due date is in the past or now
        if DUE <= NOW:
            return True

        return False

    CURRENT = next(filter(current_filter, DATA), None)

    if not CURRENT:
        CURRENT = next(
            filter(lambda x: not x.get("completed") and not x.get("allDay"), DATA), None
        )

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
    _caldav_errors.clear()
    CALENDAR: CalendarResult = get_calendar(
        url=CALDAV_URL,
        username=CALDAV_USERNAME,
        password=CALDAV_PASSWORD,
        calendar_name=CALDAV_CALENDAR,
        ssl_verify_cert=SSL_VERIFY,
    )  # pyright: ignore[reportCallIssue]

    if not CALENDAR:
        detail = _caldav_errors[-1] if _caldav_errors else "check URL, credentials, and calendar name"
        raise ValueError(
            f"Calendar '{CALDAV_CALENDAR}' not found on {CALDAV_URL}: {detail}"
        )

    TODO_EVENTS = CALENDAR.search(todo=True, include_completed=True, uid=UID)

    if not TODO_EVENTS or len(TODO_EVENTS) == 0:
        raise ValueError(f"No task found with UID: {UID}")

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
                    if (FREQ := RRULE.get("FREQ")) == ["DAILY"]:
                        due_date = COMPONENT["DUE"].dt
                        COMPONENT["DUE"].dt = due_date + timedelta(days=1)
                        COMPONENT["DTSTAMP"] = (
                            datetime.now(UTC)
                            .replace(microsecond=0)
                            .strftime("%Y%m%dT%H%M%SZ")
                        )
                    else:
                        raise NotImplementedError(
                            f"Support for task completion for repeating tasks on '{FREQ}' not implemented!"
                        )
                else:
                    COMPONENT["STATUS"] = "COMPLETED"
                    COMPONENT["COMPLETED"] = (
                        datetime.now(UTC)
                        .replace(microsecond=0)
                        .strftime("%Y%m%dT%H%M%SZ")
                    )

        TODO_EVENT.save()

        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()
        debug(TODO_EVENT_COMPONENT.get("SUMMARY"), TODO_EVENT_COMPONENT)

    return {}


def shift_due_timestamp(
    CALDAV_URL: str,
    CALDAV_USERNAME: str,
    CALDAV_PASSWORD: str,
    CALDAV_CALENDAR: str,
    UID: str,
    TIME_DELTA_MINUTES: str | int,
    SHIFT_FORWARD: str | bool,
):
    try:
        TIME_DELTA_MINUTES = int(TIME_DELTA_MINUTES)
    except ValueError:
        raise ValueError("TIME_DELTA_MINUTES must be an integer")

    try:
        SHIFT_FORWARD = bool(int(SHIFT_FORWARD))
    except ValueError:
        raise ValueError("SHIFT_FORWARD must be a boolean (0 or 1)")

    _caldav_errors.clear()
    CALENDAR: CalendarResult = get_calendar(
        url=CALDAV_URL,
        username=CALDAV_USERNAME,
        password=CALDAV_PASSWORD,
        calendar_name=CALDAV_CALENDAR,
        ssl_verify_cert=SSL_VERIFY,
    )  # pyright: ignore[reportCallIssue]

    if not CALENDAR:
        detail = _caldav_errors[-1] if _caldav_errors else "check URL, credentials, and calendar name"
        raise ValueError(
            f"Calendar '{CALDAV_CALENDAR}' not found on {CALDAV_URL}: {detail}"
        )

    TODO_EVENTS = CALENDAR.search(todo=True, include_completed=True, uid=UID)

    if not TODO_EVENTS or len(TODO_EVENTS) == 0:
        raise ValueError(f"No task found with UID: {UID}")

    debug("Shifting due date for task with UID:", UID)

    for TODO_EVENT in TODO_EVENTS:
        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()
        debug(TODO_EVENT_COMPONENT.get("SUMMARY"), TODO_EVENT_COMPONENT)

        with TODO_EVENT.edit_icalendar_component() as COMPONENT:
            if not COMPONENT.get("DUE"):
                raise ValueError("Task does not have a due date")

            DUE = COMPONENT["DUE"].dt

            if SHIFT_FORWARD:
                COMPONENT["DUE"].dt = DUE + timedelta(minutes=TIME_DELTA_MINUTES)
            else:
                COMPONENT["DUE"].dt = DUE - timedelta(minutes=TIME_DELTA_MINUTES)

            COMPONENT["DTSTAMP"] = (
                datetime.now(UTC).replace(microsecond=0).strftime("%Y%m%dT%H%M%SZ")
            )

        TODO_EVENT.save()

        TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()
        debug(TODO_EVENT_COMPONENT.get("SUMMARY"), TODO_EVENT_COMPONENT)

    return {}


def add_task(
    CALDAV_URL: str,
    CALDAV_USERNAME: str,
    CALDAV_PASSWORD: str,
    CALDAV_CALENDAR: str,
    SUMMARY: str,
):
    _caldav_errors.clear()
    CALENDAR: CalendarResult = get_calendar(
        url=CALDAV_URL,
        username=CALDAV_USERNAME,
        password=CALDAV_PASSWORD,
        calendar_name=CALDAV_CALENDAR,
        ssl_verify_cert=SSL_VERIFY,
    )  # pyright: ignore[reportCallIssue]

    if not CALENDAR:
        detail = _caldav_errors[-1] if _caldav_errors else "check URL, credentials, and calendar name"
        raise ValueError(
            f"Calendar '{CALDAV_CALENDAR}' not found on {CALDAV_URL}: {detail}"
        )

    CALENDAR.save_todo(summary=SUMMARY)

    return {}


def validate(
    CALDAV_URL: str,
    CALDAV_USERNAME: str,
    CALDAV_PASSWORD: str,
    CALDAV_CALENDAR: str,
    CALDAV_CALENDARS: str,
) -> dict[str, Any]:
    for CALENDAR in CALDAV_CALENDARS.split(",") + [CALDAV_CALENDAR]:
        try:
            CAL = get_calendar(
                url=CALDAV_URL,
                username=CALDAV_USERNAME,
                password=CALDAV_PASSWORD,
                calendar_name=CALENDAR,
                ssl_verify_cert=SSL_VERIFY,
            )  # pyright: ignore[reportCallIssue]
            if not CAL:
                raise ValueError(
                    f"Calendar {CALENDAR} not found. Check your CalDav settings."
                )
        except Exception as e:
            raise ValueError(str(e))

    return SUCCESS_PAYLOAD


if __name__ == "__main__":
    data = {}

    sys.argv.pop(0)  # remove the script name
    MODE = sys.argv.pop(0)  # remove the mode

    MODES = {
        "load": __main__,
        "toggle_complete": toggle_complete,
        "shift_due_timestamp": shift_due_timestamp,
        "add_task": add_task,
        "validate": validate,
    }

    data = FAILED_PAYLOAD
    try:
        data = MODES.get(MODE, __main__)(*sys.argv)  # pyright: ignore[reportArgumentType]
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
