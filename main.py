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

SUPPORTED_RRRULE_DELTA_FRAMES = {
    "DAILY": timedelta(days=1),
    "WEEKLY": timedelta(weeks=1),
    "MONTHLY": timedelta(days=30),
    "YEARLY": timedelta(days=365),
}

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
            detail = (
                _caldav_errors[-1]
                if _caldav_errors
                else "check URL, credentials, and calendar name"
            )
            raise ValueError(
                f"Calendar '{CALDAV_CALENDAR}' not found on {CALDAV_URL}: {detail}"
            )

        TODO_EVENTS = CALENDAR.search(
            todo=True,
            include_completed=True,
        )

        PARENT_TASKS = {}

        def get_due_from_parent(pid: str) -> datetime:
            PARENT_TASKS.setdefault(
                pid, CALENDAR.search(todo=True, include_completed=True, uid=pid)
            )

            if PARENT_TASKS[pid]:
                parent_component = PARENT_TASKS[pid][0].get_icalendar_component()
                parent_due = parent_component.get("DUE")
                if parent_due:
                    try:
                        parent_due_dt = parent_due.dt.replace(
                            tzinfo=(
                                ZoneInfo(parent_component.get("TZID"))
                                if parent_component.get("TZID")
                                else LOCAL_TZ
                            )
                        )
                        return parent_due_dt
                    except AttributeError:
                        return NOW
                    except Exception as e:
                        debug(
                            f"Error processing due date for parent task with UID {pid}: {e}"
                        )
                        return NOW

            return NOW

        for TODO_EVENT in TODO_EVENTS:
            TODO_EVENT_COMPONENT = TODO_EVENT.get_icalendar_component()

            TASK_PRIORITY = TODO_EVENT_COMPONENT.get("PRIORITY", 9)
            if PRIORITY is not None and PRIORITY >= 0 and TASK_PRIORITY != PRIORITY:
                continue

            UID = TODO_EVENT_COMPONENT.get("UID")
            SUMMARY = TODO_EVENT_COMPONENT.get("SUMMARY")

            debug(UID, SUMMARY, TODO_EVENT_COMPONENT, "\n")

            ALL_DAY = False
            DUE = TODO_EVENT_COMPONENT.get("DUE", False)

            RELATED_TO = TODO_EVENT_COMPONENT.get("RELATED-TO")
            PARENT_UID = str(RELATED_TO) if RELATED_TO else None

            try:
                DUE.dt.hour
            except AttributeError:
                ALL_DAY = True

            if RELATED_TO:
                DUE = get_due_from_parent(RELATED_TO)
            elif DUE and not ALL_DAY:
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

            STATUS = TODO_EVENT_COMPONENT.get("STATUS")
            COMPLETE = STATUS == "COMPLETED"

            RRULE = TODO_EVENT_COMPONENT.get("RRULE")

            if DUE.date() <= TODAY and not RRULE and not PARENT_UID:
                total_count += 1
                if COMPLETE:
                    complete_count += 1

            EVENT = {
                "uid": TODO_EVENT_COMPONENT.get("UID"),
                "summary": SUMMARY,
                "due": DUE,
                "completed": COMPLETE,
                "allDay": ALL_DAY,
                "priority": TODO_EVENT_COMPONENT.get("PRIORITY", 9),
                "calendar": CALDAV_CALENDAR,
                "parentUid": PARENT_UID,
                "repeating": True if RRULE else False,
            }

            DATA.append(EVENT)

    # Sort: incomplete before complete, then by due date
    DATA.sort(key=lambda x: (x.get("completed"), x.get("due")))

    # Reorder so children appear right after their parent
    def _flatten_with_children(tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
        completed_pids = set()
        children_by_parent: dict[str, list[dict[str, Any]]] = {}

        for t in tasks:
            pid = t.get("parentUid")
            if pid:
                children_by_parent.setdefault(pid, []).append(t)
            else:
                if t.get("completed"):
                    completed_pids.add(t.get("uid"))

        seen: set[str] = set()
        result: list[dict[str, Any]] = []

        for t in tasks:
            uid = t.get("uid")
            if uid in seen:
                continue
            puid = t.get("parentUid")
            if puid:
                t.update({"completed": puid in completed_pids})
                continue  # skip children in top pass; they get inserted below their parent
            seen.add(uid)
            result.append(t)

            for child in children_by_parent.get(uid, []):
                if child.get("uid") not in seen:
                    seen.add(child.get("uid"))
                    result.append(child)

        return result

    DATA = _flatten_with_children(DATA)

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

    if not CURRENT:
        CURRENT = next(filter(lambda x: not x.get("completed"), DATA), None)

    # group tasks by date, completed tasks always at the end
    INCOMPLETE = [t for t in DATA if not t["completed"]]
    COMPLETED = [t for t in DATA if t["completed"]]

    TASKS_BY_DATE = {}
    for TASK in INCOMPLETE + COMPLETED:
        if TASK["due"]:
            prefix = "z_" if TASK["completed"] else ""
            DATE = prefix + TASK["due"].date().isoformat()
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
        detail = (
            _caldav_errors[-1]
            if _caldav_errors
            else "check URL, credentials, and calendar name"
        )
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
                    FREQS = RRULE.get("FREQ")
                    INTERVALS = RRULE.get("INTERVAL", [1])
                    for FREQ in FREQS:
                        for INTERVAL in INTERVALS:
                            if DELTA := SUPPORTED_RRRULE_DELTA_FRAMES.get(FREQ):
                                DELTA *= INTERVAL
                                due_date = COMPONENT["DUE"].dt
                                COMPONENT["DUE"].dt = due_date + DELTA
                                COMPONENT["DTSTAMP"] = (
                                    datetime.now(LOCAL_TZ)
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
                        datetime.now(LOCAL_TZ)
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
        detail = (
            _caldav_errors[-1]
            if _caldav_errors
            else "check URL, credentials, and calendar name"
        )
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
                datetime.now(LOCAL_TZ).replace(microsecond=0).strftime("%Y%m%dT%H%M%SZ")
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
        detail = (
            _caldav_errors[-1]
            if _caldav_errors
            else "check URL, credentials, and calendar name"
        )
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
