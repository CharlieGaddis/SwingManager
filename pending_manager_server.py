from __future__ import annotations

import csv
import datetime as dt
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "Config" / "pending-manager.json"
MACHINE_CONFIG_PATH = ROOT / "Config" / "machine.local.json"


def resolve_runtime_root():
    configured = os.environ.get("SWING_MANAGER_RUNTIME_ROOT", "").strip()
    if not configured and MACHINE_CONFIG_PATH.exists():
        try:
            configured = str(json.loads(MACHINE_CONFIG_PATH.read_text(encoding="utf-8-sig")).get("runtimeRoot") or "").strip()
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"Could not read {MACHINE_CONFIG_PATH}: {exc}") from exc
    if not configured:
        return ROOT
    expanded = Path(os.path.expandvars(configured)).expanduser()
    return expanded if expanded.is_absolute() else ROOT / expanded


RUNTIME_ROOT = resolve_runtime_root()
ANALYSIS = RUNTIME_ROOT / "Analysis"
DATA_DIR = RUNTIME_ROOT / "Data"
STATE_PATH = DATA_DIR / "pending-state.json"
EVENT_LOG = DATA_DIR / "pending-events.jsonl"
NIGHTLY_STATUS_PATH = DATA_DIR / "nightly-workflow-status.json"
WEB_DIR = ROOT / "web"
SUBMIT_PROJECT = ROOT / "tools" / "SwingSchwabSubmit" / "SwingSchwabSubmit.csproj"
SUBMIT_DLL = ROOT / "tools" / "SwingSchwabSubmit" / "bin" / "Release" / "net8.0" / "SwingSchwabSubmit.dll"
STATE_LOCK = threading.RLock()

runtime = {
    "monitor_running": False,
    "monitor_desired": False,
    "monitor_started_at": None,
    "monitor_restart_count": 0,
    "last_monitor_error": None,
    "last_quote_error": None,
    "last_quote_refresh_at": None,
    "last_quote_freshness": None,
    "last_order_error": None,
    "last_live_preflight": None,
    "last_token_refresh_at": None,
    "last_token_refresh_error": None,
    "quotes": {},
    "working": {},
    "thread": None,
}


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def parse_utc(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def ensure_dirs():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (ROOT / "Config").mkdir(exist_ok=True)
    ANALYSIS.mkdir(parents=True, exist_ok=True)


def load_json(path: Path, default):
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def save_json(path: Path, value):
    ensure_dirs()
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2)
    tmp.replace(path)


def parse_json_from_process_output(output):
    text = str(output or "").strip()
    if not text:
        raise ValueError("Submit helper did not return JSON output.")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            return json.loads(text[start:end + 1])
        raise


def config():
    return load_json(CONFIG_PATH, {})


def live_entry_window_config():
    cfg = config().get("liveEntryWindow") or {}
    return {
        "timezone": cfg.get("timezone") or "America/New_York",
        "start": cfg.get("start") or "09:35",
        "end": cfg.get("end") or "15:30",
        "weekdaysOnly": bool(cfg.get("weekdaysOnly", True)),
    }


def parse_hhmm(value):
    match = re.match(r"^(\d{1,2}):(\d{2})$", str(value or ""))
    if not match:
        raise ValueError(f"Invalid live entry time: {value}")
    hour = int(match.group(1))
    minute = int(match.group(2))
    if hour > 23 or minute > 59:
        raise ValueError(f"Invalid live entry time: {value}")
    return dt.time(hour, minute)


def live_entry_window_status(now=None):
    window = live_entry_window_config()
    tz = ZoneInfo(window["timezone"])
    current = now.astimezone(tz) if now else dt.datetime.now(tz)
    start = parse_hhmm(window["start"])
    end = parse_hhmm(window["end"])
    local_time = current.time().replace(second=0, microsecond=0)
    weekday_ok = (not window["weekdaysOnly"]) or current.weekday() < 5
    in_window = weekday_ok and start <= local_time <= end
    return {
        "ok": in_window,
        "timezone": window["timezone"],
        "start": window["start"],
        "end": window["end"],
        "weekdaysOnly": window["weekdaysOnly"],
        "localNow": current.isoformat(),
        "reason": "within_live_entry_window" if in_window else "outside_live_entry_window",
    }


def require_live_entry_window():
    status = live_entry_window_status()
    if not status["ok"]:
        raise RuntimeError(
            f"Outside live entry window {status['start']}-{status['end']} {status['timezone']} "
            f"(now {status['localNow']})"
        )
    return status


def state():
    with STATE_LOCK:
        return load_json(STATE_PATH, {"rows": {}})


def save_state(value):
    with STATE_LOCK:
        save_json(STATE_PATH, value)


def update_row_state(row_id_value, updates):
    with STATE_LOCK:
        stored = load_json(STATE_PATH, {"rows": {}})
        row_state = stored.setdefault("rows", {}).setdefault(row_id_value, {})
        row_state.update(updates)
        save_json(STATE_PATH, stored)
        return dict(row_state)


def runtime_row_updates(row_state):
    return {
        key: value for key, value in row_state.items()
        if key not in {"enabled", "deleted"}
    }


def latest_file(pattern):
    files = sorted(ANALYSIS.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0] if files else None


def latest_queue_path():
    return latest_file("squeeze-action-queue-*.csv")


def parse_bool(value):
    return str(value).strip().lower() in {"1", "true", "yes", "y"}


def money(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def row_id(row):
    return "|".join([
        row.get("Account", ""),
        row.get("AssetType", ""),
        row.get("Key", ""),
        row.get("TriggerSymbol", ""),
        row.get("ContractLabel", ""),
        row.get("TriggerOperator", ""),
        str(row.get("TriggerPrice", "")),
    ])




def read_csv_rows(path, limit=None):
    if path is None or not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(dict(row))
            if limit and len(rows) >= limit:
                break
    return rows


def load_oco_review():
    reconciliation_path = latest_file("tos-oco-reconciliation-*.csv")
    api_worksheet_path = latest_file("schwab-working-orders-api-reconciliation-*.csv")
    update_path = latest_file("swing-oco-update-queue-*.csv")
    queue_path = latest_queue_path()
    desktop_batch_path, desktop_batch = load_desktop_oco_batch()
    reconciliation = read_csv_rows(reconciliation_path)
    api_worksheet = build_api_oco_worksheet(read_csv_rows(api_worksheet_path))
    update_rows = read_csv_rows(update_path)
    json_updates = []
    if queue_path:
        json_updates = [row for row in read_csv_rows(queue_path) if row.get("Action") == "OCO_REVIEW_REQUIRED"]
    counts = {}
    for row in reconciliation:
        status = row.get("ReconcileStatus") or "UNKNOWN"
        counts[status] = counts.get(status, 0) + 1
    return {
        "reconciliationPath": str(reconciliation_path) if reconciliation_path else None,
        "apiWorksheetPath": str(api_worksheet_path) if api_worksheet_path else None,
        "updateQueuePath": str(update_path) if update_path else None,
        "actionQueuePath": str(queue_path) if queue_path else None,
        "desktopBatchPath": str(desktop_batch_path) if desktop_batch_path else None,
        "desktopBatch": {
            "itemCount": desktop_batch.get("itemCount", 0),
            "updateCount": desktop_batch.get("updateCount", 0),
            "readyCount": desktop_batch.get("readyCount", 0),
            "missingProtectionCount": desktop_batch.get("missingProtectionCount", 0),
            "targetAccount": desktop_batch.get("targetAccount", {}),
            "currentTosAccount": desktop_batch.get("currentTosAccount", {}),
            "readyItems": desktop_oco_ready_items(desktop_batch),
            "updateItems": desktop_oco_update_items(desktop_batch),
        },
        "counts": counts,
        "apiWorksheet": api_worksheet,
        "reconciliation": reconciliation,
        "updateQueue": update_rows,
        "jsonUpdates": json_updates,
    }


def api_oco_status(row):
    status = row.get("ApiInventoryStatus") or "UNKNOWN"
    if status == "NO_WORKING_ORDER_FOUND_BY_API":
        return "MISSING_PROTECTION"
    if status == "OCO_STRUCTURE_FOUND_CONDITION_LEVELS_NOT_RETURNED":
        return "API_CONFIRMED_STRUCTURE_MANUAL_VERIFY_TARGETS"
    if status == "STOP_FOUND_TARGET_MISSING":
        return "API_CONFIRMED_STOP_ONLY"
    if status == "TARGET_FOUND_STOP_MISSING":
        return "API_TARGET_FOUND_STOP_MISSING"
    if status == "WORKING_ORDER_FOUND_UNCLASSIFIED":
        return "API_STRUCTURE_REVIEW"
    return status


def api_oco_next_action(row):
    status = api_oco_status(row)
    if status == "MISSING_PROTECTION":
        return "Build or locate OCO protection."
    if status == "API_CONFIRMED_STRUCTURE_MANUAL_VERIFY_TARGETS":
        return "API found OCO children and stop; manually verify target trigger levels if needed."
    if status == "API_CONFIRMED_STOP_ONLY":
        return "Target children were not found by API; review protection."
    if status == "API_TARGET_FOUND_STOP_MISSING":
        return "Stop child was not found by API; review protection."
    return "Review API order structure."


def build_api_oco_worksheet(rows):
    worksheet = []
    for row in rows:
        worksheet.append({
            "Account": row.get("Account", ""),
            "ExpectedAccountEnding": row.get("ExpectedAccountEnding", ""),
            "Portfolio": row.get("Portfolio", ""),
            "Ticker": row.get("Ticker", ""),
            "ContractLabel": row.get("ContractLabel", ""),
            "ExpectedStop": row.get("ExpectedStop", ""),
            "ExpectedT1": row.get("ExpectedT1", ""),
            "ExpectedT2": row.get("ExpectedT2", ""),
            "ApiWorkingChildRows": row.get("ApiWorkingChildRows", ""),
            "ApiTargetChildren": row.get("ApiTargetChildren", ""),
            "ApiStopChildren": row.get("ApiStopChildren", ""),
            "ApiParentOcoIds": row.get("ApiParentOcoIds", ""),
            "ApiStopPrices": row.get("ApiStopPrices", ""),
            "ApiConditionThresholds": row.get("ApiConditionThresholds", ""),
            "ApiInventoryStatus": row.get("ApiInventoryStatus", ""),
            "WorksheetStatus": api_oco_status(row),
            "NextAction": api_oco_next_action(row),
        })
    return worksheet


def load_worklist_review():
    worklist_path = latest_file("swing-nightly-worklist-*.csv")
    update_queue_path = latest_file("swing-oco-update-queue-*.csv")
    update_levels_path = latest_file("swing-oco-update-levels-*.csv")
    exceptions_path = latest_file("swing-oco-exceptions-review-*.csv")
    desktop_batch_path = latest_file("tos-oco-desktop-update-batch-*.json")
    worklist = read_csv_rows(worklist_path)
    update_queue = read_csv_rows(update_queue_path)
    update_levels = read_csv_rows(update_levels_path)
    exceptions = read_csv_rows(exceptions_path)
    desktop_batch = load_json(desktop_batch_path, {}) if desktop_batch_path else {}
    counts = {}
    for row in worklist:
        priority = row.get("Priority") or "UNKNOWN"
        counts[priority] = counts.get(priority, 0) + 1
    blocking_priorities = {"MISSING_OCO", "UPDATE_OCO", "BUILD_OCO", "JSON_CHANGED", "ORDER_STRUCTURE_REVIEW", "LOCATE_IN_TOS"}
    blocking = [row for row in worklist if row.get("Priority") in blocking_priorities]
    return {
        "worklistPath": str(worklist_path) if worklist_path else None,
        "updateQueuePath": str(update_queue_path) if update_queue_path else None,
        "updateLevelsPath": str(update_levels_path) if update_levels_path else None,
        "exceptionsPath": str(exceptions_path) if exceptions_path else None,
        "desktopBatchPath": str(desktop_batch_path) if desktop_batch_path else None,
        "desktopBatchItemCount": desktop_batch.get("itemCount", 0),
        "desktopBatchUpdateCount": desktop_batch.get("updateCount", 0),
        "desktopBatchReadyCount": desktop_batch.get("readyCount", 0),
        "desktopBatchMissingProtectionCount": desktop_batch.get("missingProtectionCount", 0),
        "counts": counts,
        "blockingCount": len(blocking),
        "updateQueueCount": len(update_queue),
        "updateLevelCount": len(update_levels),
        "exceptionCount": len(exceptions),
        "blocking": blocking,
        "updateQueue": update_queue,
        "updateLevels": update_levels,
        "exceptions": exceptions,
    }


def workflow_status():
    base = load_json(NIGHTLY_STATUS_PATH, {})
    rows, queue_path = load_pending_rows()
    oco = load_oco_review()
    worklist = load_worklist_review()
    base.update({
        "queuePath": queue_path,
        "pendingCount": len(rows),
        "ocoCounts": oco.get("counts", {}),
        "ocoReconciliationPath": oco.get("reconciliationPath"),
        "ocoUpdateQueuePath": oco.get("updateQueuePath"),
        "actionQueuePath": oco.get("actionQueuePath"),
        "worklistPath": worklist.get("worklistPath"),
        "worklistCounts": worklist.get("counts", {}),
        "worklistBlockingCount": worklist.get("blockingCount", 0),
        "ocoUpdateLevelCount": worklist.get("updateLevelCount", 0),
        "ocoUpdateLevelsPath": worklist.get("updateLevelsPath"),
        "desktopOcoBatchPath": worklist.get("desktopBatchPath"),
        "desktopOcoBatchItemCount": worklist.get("desktopBatchItemCount", 0),
        "desktopOcoBatchUpdateCount": worklist.get("desktopBatchUpdateCount", 0),
        "desktopOcoBatchReadyCount": worklist.get("desktopBatchReadyCount", 0),
        "desktopOcoBatchMissingProtectionCount": worklist.get("desktopBatchMissingProtectionCount", 0),
    })
    return base


def save_workflow_status(patch):
    current = load_json(NIGHTLY_STATUS_PATH, {})
    current.update(patch)
    current["updatedAt"] = utc_now()
    save_json(NIGHTLY_STATUS_PATH, current)
    return current


def safe_upload_name(filename):
    name = Path(filename or "squeeze-intel-upload.json").name
    name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
    if not name.lower().endswith(".json"):
        name += ".json"
    if not name.startswith("squeeze-intel-"):
        stamp = dt.datetime.now().strftime("%Y-%m-%d-%H%M%S")
        name = f"squeeze-intel-upload-{stamp}-{name}"
    return name


def save_uploaded_json(filename, content):
    ensure_dirs()
    if isinstance(content, dict) and "value" in content:
        content = content.get("value")
    if not isinstance(content, str) or not content.strip():
        raise ValueError("Uploaded JSON content is empty.")
    parsed = json.loads(content)
    name = safe_upload_name(filename)
    target = ANALYSIS / name
    with target.open("w", encoding="utf-8") as handle:
        json.dump(parsed, handle, indent=2)
    return target, parsed


def previous_json_for(source_path: Path):
    parsed = load_json(source_path, {})
    scan_date = parsed.get("scan_date") if isinstance(parsed, dict) else ""
    if not scan_date:
        return None
    try:
        previous = dt.datetime.fromisoformat(str(scan_date)).date() - dt.timedelta(days=1)
    except ValueError:
        return None
    path = ANALYSIS / f"squeeze-intel-{previous.isoformat()}.json"
    return path if path.exists() else None


def run_nightly_reconciliation(source_path: Path, target_account="", tos_reconciliation_path="", tos_visible_orders_path="", tos_snapshot_json=""):
    script = ROOT / "Invoke-SwingNightlyReconciliation.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing nightly reconciliation script: {script}")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-TodayPath",
        str(source_path),
        "-OutDir",
        str(ANALYSIS),
        "-TradingDashboardBaseUrl",
        config().get("tradingDashboardBaseUrl", "http://127.0.0.1:5080"),
    ]
    previous = previous_json_for(source_path)
    if previous:
        command.extend(["-PreviousPath", str(previous)])
    tos = Path(tos_reconciliation_path) if tos_reconciliation_path else latest_file("tos-oco-reconciliation-*.csv")
    if tos:
        command.extend(["-TosReconciliationPath", str(tos)])
    if tos_visible_orders_path:
        command.extend(["-TosVisibleOrdersPath", str(tos_visible_orders_path)])
    if tos_snapshot_json:
        command.extend(["-TosSnapshotJson", str(tos_snapshot_json)])
    if target_account:
        command.extend(["-TargetAccount", str(target_account)])
    started = utc_now()
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=180)
    status = {
        "lastReconcileStartedAt": started,
        "lastReconcileFinishedAt": utc_now(),
        "lastReconcileOk": result.returncode == 0,
        "lastReconcileCommand": " ".join(command),
        "lastReconcileStdout": result.stdout[-6000:],
        "lastReconcileStderr": result.stderr[-6000:],
        "lastReconcileError": "",
    }
    save_workflow_status(status)
    if result.returncode != 0:
        save_workflow_status({"lastReconcileOk": False, "lastReconcileError": result.stderr.strip() or result.stdout.strip() or "Nightly reconciliation failed."})
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Nightly reconciliation failed.")
    return workflow_status()


def load_desktop_oco_batch():
    path = latest_file("tos-oco-desktop-update-batch-*.json")
    if not path:
        return None, {}
    return path, load_json(path, {})


def desktop_oco_ready_items(batch):
    items = batch.get("items") or []
    ready = []
    for item in items:
        status = str(item.get("SnapshotStatus") or "").strip().upper()
        if status in {"CANCELED", "FILLED"}:
            continue
        if item.get("Action") == "update_condition_threshold" and item.get("ReadyForDesktopAutomation") is True and item.get("AccountVerified") is True:
            ready.append(item)
    return ready


def desktop_oco_update_items(batch):
    items = batch.get("items") or []
    updates = []
    for item in items:
        status = str(item.get("SnapshotStatus") or "").strip().upper()
        if status in {"CANCELED", "FILLED"}:
            continue
        if item.get("Action") == "update_condition_threshold":
            updates.append(item)
    return updates


def run_desktop_oco_batch_plan(body):
    script = ROOT / "tools" / "Invoke-TosOcoDesktopBatch.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing desktop OCO batch runner: {script}")
    batch_path = body.get("batchPath") or workflow_status().get("desktopOcoBatchPath")
    if not batch_path:
        raise RuntimeError("No desktop OCO batch plan is available. Build the OCO worklist first.")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-BatchPath",
        str(batch_path),
        "-Mode",
        "Plan",
    ]
    for body_key, switch_name in (("symbol", "-Symbol"), ("phase", "-Phase"), ("ocoId", "-OcoId"), ("replacingOrderId", "-ReplacingOrderId")):
        value = str(body.get(body_key) or "").strip()
        if value:
            command.extend([switch_name, value])
    started = utc_now()
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=60)
    status = {
        "lastDesktopOcoPlanStartedAt": started,
        "lastDesktopOcoPlanFinishedAt": utc_now(),
        "lastDesktopOcoPlanOk": result.returncode == 0,
        "lastDesktopOcoPlanCommand": " ".join(command),
        "lastDesktopOcoPlanStdout": result.stdout[-6000:],
        "lastDesktopOcoPlanStderr": result.stderr[-6000:],
        "lastDesktopOcoPlanError": "",
    }
    save_workflow_status(status)
    parsed = None
    try:
        parsed = parse_json_from_process_output(result.stdout)
    except Exception:
        parsed = None
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "Desktop OCO plan failed."
        save_workflow_status({"lastDesktopOcoPlanOk": False, "lastDesktopOcoPlanError": message})
        raise RuntimeError(message)
    return parsed or {"ok": True, "stdout": result.stdout}


def run_desktop_oco_workflow(body):
    script = ROOT / "tools" / "Invoke-TosOcoDesktopWorkflow.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing desktop OCO workflow runner: {script}")
    batch_path = body.get("batchPath") or workflow_status().get("desktopOcoBatchPath")
    if not batch_path:
        raise RuntimeError("No desktop OCO batch is available. Build the OCO worklist first.")
    stage = str(body.get("stage") or "RunToConfirmation")
    allowed_stages = {"Plan", "OpenCancelReplace", "SetThreshold", "OpenConfirmation", "VerifyConfirmation", "FinalSend", "RunToConfirmation", "RunToFinalSend"}
    if stage not in allowed_stages:
        raise RuntimeError(f"Unsupported desktop OCO workflow stage: {stage}")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-BatchPath",
        str(batch_path),
        "-Stage",
        stage,
    ]
    for body_key, switch_name in (("symbol", "-Symbol"), ("phase", "-Phase"), ("ocoId", "-OcoId"), ("replacingOrderId", "-ReplacingOrderId")):
        value = str(body.get(body_key) or "").strip()
        if value:
            command.extend([switch_name, value])
    if body.get("allowInput") or stage in {"OpenCancelReplace", "SetThreshold", "OpenConfirmation", "FinalSend", "RunToConfirmation", "RunToFinalSend"}:
        command.append("-AllowInput")
    if body.get("allowFinalSend"):
        command.append("-AllowFinalSend")
    started = utc_now()
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=240)
    status = {
        "lastDesktopOcoWorkflowStartedAt": started,
        "lastDesktopOcoWorkflowFinishedAt": utc_now(),
        "lastDesktopOcoWorkflowOk": result.returncode == 0,
        "lastDesktopOcoWorkflowStage": stage,
        "lastDesktopOcoWorkflowCommand": " ".join(command),
        "lastDesktopOcoWorkflowStdout": result.stdout[-9000:],
        "lastDesktopOcoWorkflowStderr": result.stderr[-9000:],
        "lastDesktopOcoWorkflowError": "",
    }
    save_workflow_status(status)
    parsed = None
    try:
        parsed = parse_json_from_process_output(result.stdout)
    except Exception:
        parsed = None
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "Desktop OCO workflow failed."
        save_workflow_status({"lastDesktopOcoWorkflowOk": False, "lastDesktopOcoWorkflowError": message})
        raise RuntimeError(message)
    return parsed or {"ok": True, "stdout": result.stdout}


def refresh_current_tos_batch():
    status = workflow_status()
    source = status.get("lastUploadPath") or status.get("sourceJson")
    if not source:
        return None
    source_path = Path(source)
    run_nightly_update(source_path, capture_tos=True)
    return run_nightly_reconciliation(source_path)


def run_next_desktop_oco_workflow(body):
    batch_path, batch = load_desktop_oco_batch()
    if not batch_path:
        raise RuntimeError("No desktop OCO batch is available. Build the OCO worklist first.")
    ready = desktop_oco_ready_items(batch)
    if not ready:
        return {"success": True, "message": "No ready desktop OCO updates.", "remainingReadyCount": 0}
    item = ready[0]
    target_account = item.get("TargetAccountAlias") or item.get("CurrentTosAccountAlias") or ""
    payload = {
        "batchPath": str(batch_path),
        "symbol": item.get("Symbol", ""),
        "phase": item.get("Phase", ""),
        "ocoId": item.get("OcoId", ""),
        "replacingOrderId": item.get("ReplacingOrderId", ""),
        "stage": body.get("stage") or "RunToConfirmation",
        "allowInput": True,
        "allowFinalSend": bool(body.get("allowFinalSend")),
    }
    result = run_desktop_oco_workflow(payload)
    refreshed = None
    if payload["stage"] == "RunToFinalSend" and bool(result.get("success", True)):
        if target_account in {"IRA", "Living Trust"}:
            refreshed = prepare_tos_account_batch({"account": target_account})
        else:
            refreshed = refresh_current_tos_batch()
    return {
        "selected": payload,
        "result": result,
        "refreshed": refreshed is not None,
        "success": bool(result.get("success", True)),
    }
def run_nightly_update(source_path: Path, capture_tos=False):
    script = ROOT / "Update-SwingManagerNightly.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing nightly update script: {script}")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-SourcePath",
        str(source_path),
        "-OutDir",
        str(ANALYSIS),
    ]
    if capture_tos:
        command.append("-CaptureTos")
    started = utc_now()
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=180)
    status = {
        "lastRunStartedAt": started,
        "lastRunFinishedAt": utc_now(),
        "lastRunOk": result.returncode == 0,
        "lastRunCommand": " ".join(command),
        "lastRunStdout": result.stdout[-6000:],
        "lastRunStderr": result.stderr[-6000:],
        "lastRunError": "",
        "sourceJson": str(source_path),
        "captureTos": bool(capture_tos),
    }
    save_workflow_status(status)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Nightly update failed.")
    return workflow_status()


def run_tos_account_switch(target_account):
    if target_account not in {"IRA", "Living Trust"}:
        raise RuntimeError(f"Unsupported TOS target account: {target_account}")
    script = ROOT / "tools" / "Switch-TosAccount.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing TOS account switch script: {script}")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-TargetAccount",
        target_account,
        "-AllowInput",
    ]
    started = utc_now()
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=120)
    save_workflow_status({
        "lastTosAccountSwitchStartedAt": started,
        "lastTosAccountSwitchFinishedAt": utc_now(),
        "lastTosAccountSwitchOk": result.returncode == 0,
        "lastTosAccountSwitchTarget": target_account,
        "lastTosAccountSwitchCommand": " ".join(command),
        "lastTosAccountSwitchStdout": result.stdout[-6000:],
        "lastTosAccountSwitchStderr": result.stderr[-6000:],
        "lastTosAccountSwitchError": "",
    })
    parsed = None
    try:
        parsed = parse_json_from_process_output(result.stdout)
    except Exception:
        parsed = None
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"TOS account switch to {target_account} failed."
        save_workflow_status({"lastTosAccountSwitchOk": False, "lastTosAccountSwitchError": message})
        raise RuntimeError(message)
    return parsed or {"ok": True, "stdout": result.stdout}


def ensure_tos_monitor_working_orders():
    script = ROOT / "tools" / "Ensure-TosMonitorWorkingOrders.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing TOS working-orders guard: {script}")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-WindowTitle",
        "Main@thinkorswim",
        "-AllowInput",
    ]
    started = utc_now()
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=420)
    save_workflow_status({
        "lastTosWorkingOrdersGuardStartedAt": started,
        "lastTosWorkingOrdersGuardFinishedAt": utc_now(),
        "lastTosWorkingOrdersGuardOk": result.returncode == 0,
        "lastTosWorkingOrdersGuardCommand": " ".join(command),
        "lastTosWorkingOrdersGuardStdout": result.stdout[-6000:],
        "lastTosWorkingOrdersGuardStderr": result.stderr[-6000:],
        "lastTosWorkingOrdersGuardError": "",
    })
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "TOS is not ready on Monitor > Working Orders."
        save_workflow_status({"lastTosWorkingOrdersGuardOk": False, "lastTosWorkingOrdersGuardError": message})
        raise RuntimeError(message)
    try:
        return parse_json_from_process_output(result.stdout)
    except Exception:
        return {"ok": True, "stdout": result.stdout}


def capture_tos_snapshot(label):
    script = ROOT / "tools" / "New-TosAutomationSnapshot.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing TOS snapshot script: {script}")
    safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-") or "snapshot"
    discovery = ROOT / "TosAutomation" / "Discovery"
    started = time.time()
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-WindowTitle",
        "Main@thinkorswim",
        "-Label",
        safe_label,
        "-MaxDepth",
        "45",
        "-MaxChildrenPerNode",
        "1200",
    ]
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "TOS snapshot failed.")
    candidates = sorted(
        discovery.glob(f"tos-{safe_label}-*-tree.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    snapshot_json = next((p for p in candidates if p.stat().st_mtime >= started - 2), candidates[0] if candidates else None)
    if not snapshot_json:
        raise RuntimeError(f"TOS snapshot did not produce a JSON tree for label {safe_label}.")
    tree_path = Path(str(snapshot_json).replace("-tree.json", "-tree.txt"))
    if not tree_path.exists():
        raise RuntimeError(f"TOS snapshot JSON was found but tree text is missing: {tree_path}")
    return {"json": snapshot_json, "tree": tree_path, "stdout": result.stdout}


def extract_tos_working_orders(tree_path, action_queue_path):
    script = ROOT / "Extract-TosWorkingOrdersFromTree.ps1"
    if not script.exists():
        raise FileNotFoundError(f"Missing TOS working-order extractor: {script}")
    started = time.time()
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-TreePath",
        str(tree_path),
        "-ActionQueuePath",
        str(action_queue_path),
        "-OutDir",
        str(ANALYSIS),
    ]
    result = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, timeout=120)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "TOS working-order extraction failed.")
    visible = sorted(ANALYSIS.glob("tos-visible-working-orders-*.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    recon = sorted(ANALYSIS.glob("tos-oco-reconciliation-*.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    visible_path = next((p for p in visible if p.stat().st_mtime >= started - 2), visible[0] if visible else None)
    recon_path = next((p for p in recon if p.stat().st_mtime >= started - 2), recon[0] if recon else None)
    if not visible_path or not recon_path:
        raise RuntimeError("TOS extraction did not produce visible-order and reconciliation CSV files.")
    return {"visible": visible_path, "reconciliation": recon_path, "stdout": result.stdout}


def prepare_tos_account_batch(body):
    account = str(body.get("account") or "").strip()
    if account not in {"IRA", "Living Trust"}:
        raise RuntimeError("account must be IRA or Living Trust.")
    source = body.get("sourcePath") or workflow_status().get("lastUploadPath") or workflow_status().get("sourceJson")
    if not source:
        raise RuntimeError("Upload a JSON file before preparing an account-scoped TOS batch.")
    source_path = Path(source)
    if not latest_queue_path():
        run_nightly_update(source_path, capture_tos=False)
    queue_path = latest_queue_path()
    if not queue_path:
        raise RuntimeError("No action queue is available after building the nightly update.")
    switch_result = run_tos_account_switch(account)
    monitor_guard = ensure_tos_monitor_working_orders()
    snapshot = capture_tos_snapshot(f"AccountScopedOco-{account}")
    extracted = extract_tos_working_orders(snapshot["tree"], queue_path)
    status = run_nightly_reconciliation(
        source_path,
        target_account=account,
        tos_reconciliation_path=str(extracted["reconciliation"]),
        tos_visible_orders_path=str(extracted["visible"]),
        tos_snapshot_json=str(snapshot["json"]),
    )
    return {
        "success": True,
        "account": account,
        "switch": switch_result,
        "monitorWorkingOrdersGuard": monitor_guard,
        "snapshotJson": str(snapshot["json"]),
        "snapshotTree": str(snapshot["tree"]),
        "visibleOrdersPath": str(extracted["visible"]),
        "tosReconciliationPath": str(extracted["reconciliation"]),
        "status": status,
    }
def load_pending_rows():
    path = latest_queue_path()
    if path is None:
        return [], None
    stored = state().get("rows", {})
    rows = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        for raw in csv.DictReader(handle):
            if raw.get("Action") != "PENDING_ENTRY_TRIGGER":
                continue
            ident = row_id(raw)
            local = stored.get(ident, {})
            if local.get("deleted"):
                continue
            trigger_price = money(raw.get("TriggerPrice"))
            latest = runtime["quotes"].get(raw.get("TriggerSymbol", "").upper(), {})
            status = local.get("status") or "armed"
            row = dict(raw)
            row.update({
                "id": ident,
                "enabled": bool(local.get("enabled", True)),
                "deleted": False,
                "status": status,
                "schwabOrderId": local.get("schwabOrderId", ""),
                "brokerStatus": local.get("brokerStatus", ""),
                "brokerEnteredTime": local.get("brokerEnteredTime", ""),
                "filledQuantity": local.get("filledQuantity", ""),
                "remainingQuantity": local.get("remainingQuantity", ""),
                "submittedPhase": local.get("submittedPhase", ""),
                "submittedLimit": local.get("submittedLimit", ""),
                "cancelReplaceCount": local.get("cancelReplaceCount", 0),
                "lastQuote": latest,
                "distance": quote_distance(latest, raw.get("TriggerOperator"), trigger_price),
                "triggerHit": is_trigger_hit(latest, raw.get("TriggerOperator"), trigger_price),
                "orderPlan": build_order_plan(raw, latest, local),
                "lastEvent": local.get("lastEvent", ""),
                "updatedAt": local.get("updatedAt", ""),
            })
            rows.append(row)
    return rows, str(path)


def quote_price(quote):
    q = quote_bid_ask_mark(quote or {})
    return q.get("mark") if q.get("mark") is not None else q.get("last")


def quote_bid_ask_mark(quote):
    flat = flatten_quote(quote)
    bid = flat.get("bidPrice") or flat.get("bid")
    ask = flat.get("askPrice") or flat.get("ask")
    mark = flat.get("mark") or flat.get("markPrice")
    last = flat.get("lastPrice") or flat.get("last") or flat.get("regularMarketLastPrice")
    try:
        bid = float(bid) if bid is not None else None
    except (TypeError, ValueError):
        bid = None
    try:
        ask = float(ask) if ask is not None else None
    except (TypeError, ValueError):
        ask = None
    try:
        mark = float(mark) if mark is not None else None
    except (TypeError, ValueError):
        mark = None
    if mark is None and bid is not None and ask is not None:
        mark = round((bid + ask) / 2, 4)
    try:
        last = float(last) if last is not None else None
    except (TypeError, ValueError):
        last = None
    return {"bid": bid, "ask": ask, "mark": mark, "last": last}


def flatten_quote(quote):
    flat = dict(quote or {})
    for key in ("quote", "regular", "fundamental"):
        if isinstance((quote or {}).get(key), dict):
            flat.update((quote or {})[key])
    return flat


QUOTE_TIME_KEYS = {
    "quoteTime",
    "quoteTimeInLong",
    "tradeTime",
    "tradeTimeInLong",
    "bidTime",
    "bidTimeInLong",
    "askTime",
    "askTimeInLong",
    "regularMarketTradeTime",
    "regularMarketTradeTimeInLong",
}


def quote_timestamp(value):
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        seconds = value / 1000 if value > 10_000_000_000 else value
        try:
            return dt.datetime.fromtimestamp(seconds, dt.timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    if isinstance(value, str):
        parsed = parse_utc(value)
        if parsed:
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
        try:
            numeric = float(value)
        except ValueError:
            return None
        return quote_timestamp(numeric)
    return None


def latest_quote_timestamp(quote):
    flat = flatten_quote(quote)
    timestamps = [quote_timestamp(flat.get(key)) for key in QUOTE_TIME_KEYS]
    timestamps = [value for value in timestamps if value is not None]
    return max(timestamps) if timestamps else None


def validate_quote_freshness(quotes):
    window_status = live_entry_window_status()
    max_age_seconds = int(config().get("maxQuoteAgeSeconds", 180))
    runtime["last_quote_freshness"] = {
        "checkedAt": utc_now(),
        "maxQuoteAgeSeconds": max_age_seconds,
        "liveEntryWindowOk": window_status["ok"],
        "stale": [],
    }
    if not window_status["ok"] or not quotes:
        return
    now = dt.datetime.now(dt.timezone.utc)
    stale = []
    for symbol, quote in sorted(quotes.items()):
        timestamp = latest_quote_timestamp(quote)
        if timestamp is None:
            stale.append(f"{symbol}: missing quote timestamp")
            continue
        age_seconds = (now - timestamp.astimezone(dt.timezone.utc)).total_seconds()
        if age_seconds > max_age_seconds:
            stale.append(f"{symbol}: {int(age_seconds)}s old")
    runtime["last_quote_freshness"]["stale"] = stale
    if stale:
        raise RuntimeError("Stale Schwab quotes during live entry window: " + "; ".join(stale[:12]))


def quote_distance(quote, operator, trigger):
    price = quote_price(quote or {})
    if price is None or trigger is None:
        return None
    if operator == "<=":
        return round(price - trigger, 2)
    if operator == ">=":
        return round(trigger - price, 2)
    return None


def is_trigger_hit(quote, operator, trigger):
    price = quote_price(quote or {})
    if price is None or trigger is None:
        return False
    if operator == "<=":
        return price <= trigger
    if operator == ">=":
        return price >= trigger
    return False


def parse_contract_label(label):
    if not label:
        return []
    match = re.match(r"(?P<strikes>[0-9.]+(?:/[0-9.]+)*)\s*(?P<right>[CP])\s+(?P<month>\d{2})-(?P<day>\d{2})", label.strip(), re.I)
    if not match:
        return []
    today = dt.date.today()
    month = int(match.group("month"))
    day = int(match.group("day"))
    expiration_date = dt.date(today.year, month, day)
    if expiration_date < today:
        expiration_date = dt.date(today.year + 1, month, day)
    expiration = expiration_date.isoformat()
    right = "CALL" if match.group("right").upper() == "C" else "PUT"
    strikes = [float(x) for x in match.group("strikes").split("/")]
    return [{"expiration": expiration, "right": right, "strike": strike} for strike in strikes]


def build_order_plan(row, quote, local):
    asset = row.get("AssetType")
    q = quote_bid_ask_mark(quote or {})
    quantity = int(float(row.get("Quantity") or 0))
    if asset == "stock":
        return {
            "method": "BUY_LIMIT_LADDER",
            "strategyLabel": "Stock bid for 60s, then mark",
            "account": row.get("Account"),
            "instruction": "BUY",
            "symbol": row.get("Ticker"),
            "quantity": quantity,
            "initialLimit": q["bid"],
            "afterSeconds": 60,
            "thenLimit": q["mark"],
            "refreshSeconds": 15,
        }
    legs = parse_contract_label(row.get("ContractLabel", ""))
    instructions = []
    structure = str(row.get("Structure") or "").lower()
    if len(legs) == 1:
        instructions.append({**legs[0], "instruction": "BUY_TO_OPEN", "quantity": quantity})
    elif len(legs) >= 2 and structure == "put_credit_spread":
        instructions.append({**legs[0], "instruction": "SELL_TO_OPEN", "quantity": quantity})
        instructions.append({**legs[1], "instruction": "BUY_TO_OPEN", "quantity": quantity})
    elif len(legs) >= 2:
        instructions.append({**legs[0], "instruction": "BUY_TO_OPEN", "quantity": quantity})
        instructions.append({**legs[1], "instruction": "SELL_TO_OPEN", "quantity": quantity})
    return {
        "method": "OPTION_BID_SIDE_THEN_MARK_LADDER",
        "strategyLabel": "Option/spread bid-side price for 60s, then mark",
        "account": row.get("Account"),
        "underlying": row.get("Ticker"),
        "contractLabel": row.get("ContractLabel"),
        "quantity": quantity,
        "initialPriceBasis": "BID_SIDE_DEBIT",
        "fallbackAfterSeconds": 60,
        "fallbackPriceBasis": "MARK",
        "refreshSeconds": 15,
        "legs": instructions,
    }


def append_event(row_id_value, level, message, extra=None):
    payload = {
        "ts": utc_now(),
        "rowId": row_id_value,
        "level": level,
        "message": message,
        "extra": extra or {},
    }
    with STATE_LOCK:
        ensure_dirs()
        with EVENT_LOG.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
        stored = load_json(STATE_PATH, {"rows": {}})
        stored.setdefault("rows", {}).setdefault(row_id_value, {})
        stored["rows"][row_id_value].update({
            "lastEvent": message,
            "updatedAt": payload["ts"],
        })
        save_json(STATE_PATH, stored)


def fetch_quotes(symbols):
    symbols = sorted({s.upper() for s in symbols if s})
    if not symbols:
        return {}
    base = config().get("tradingDashboardBaseUrl", "http://127.0.0.1:5080").rstrip("/")
    url = base + "/api/schwab/quotes?" + urllib.parse.urlencode({"symbols": ",".join(symbols)})
    with urllib.request.urlopen(url, timeout=8) as response:
        data = json.loads(response.read().decode("utf-8"))
    if isinstance(data, dict) and all(isinstance(v, dict) for v in data.values()):
        return {str(k).upper(): v for k, v in data.items()}
    return {}


def refresh_dashboard_token(force=False):
    if config().get("executionMode", "paper") != "live":
        return
    now = dt.datetime.now(dt.timezone.utc)
    cadence_seconds = int(config().get("tokenRefreshSeconds", 600))
    last = parse_utc(runtime.get("last_token_refresh_at"))
    if (
        not force
        and last is not None
        and (now - last).total_seconds() < max(60, cadence_seconds)
    ):
        return
    base = config().get("tradingDashboardBaseUrl", "http://127.0.0.1:5080").rstrip("/")
    request = urllib.request.Request(
        base + "/api/schwab/refresh-token",
        data=b"{}",
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        status = json.loads(response.read().decode("utf-8"))
    runtime["last_token_refresh_at"] = utc_now()
    runtime["last_token_refresh_error"] = None
    if not status.get("connected"):
        raise RuntimeError("TradingDashboard Schwab connection is not connected.")


def refresh_quotes():
    rows, _ = load_pending_rows()
    symbols = [row["TriggerSymbol"] for row in rows]
    try:
        refresh_dashboard_token()
        quotes = fetch_quotes(symbols)
        validate_quote_freshness(quotes)
        runtime["quotes"] = quotes
        runtime["last_quote_refresh_at"] = utc_now()
        runtime["last_quote_error"] = None
    except (urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as exc:
        if isinstance(exc, urllib.error.HTTPError) and exc.code == 401:
            try:
                refresh_dashboard_token(force=True)
                quotes = fetch_quotes(symbols)
                validate_quote_freshness(quotes)
                runtime["quotes"] = quotes
                runtime["last_quote_refresh_at"] = utc_now()
                runtime["last_quote_error"] = None
                return
            except (urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as retry_exc:
                runtime["last_token_refresh_error"] = str(retry_exc)
                runtime["last_quote_error"] = str(retry_exc)
        else:
            runtime["last_quote_error"] = str(exc)
        runtime["quotes"] = {}


def monitor_loop_body():
    while runtime["monitor_running"]:
        refresh_quotes()
        reconcile_live_orders()
        if runtime["last_quote_error"]:
            time.sleep(max(1, int(config().get("quotePollSeconds", 5))))
            continue
        rows, _ = load_pending_rows()
        stored = state()
        for row in rows:
            if not row["enabled"]:
                continue
            ident = row["id"]
            local = stored.setdefault("rows", {}).setdefault(ident, {})
            mode = config().get("executionMode", "paper")
            status = local.get("status")
            blocked_statuses = {"live_submitted", "live_submit_failed"}
            if mode == "paper":
                blocked_statuses.add("paper_submitted")
            already_has_live_order = bool(local.get("schwabOrderId"))
            if mode == "live" and already_has_live_order:
                try:
                    if maybe_replace_with_mark(row, local):
                        stored = state()
                        local = stored.setdefault("rows", {}).setdefault(ident, {})
                except Exception as exc:
                    local["status"] = "live_replace_failed"
                    append_event(ident, "error", f"Live cancel/replace failed: {exc}", {"orderId": local.get("schwabOrderId", "")})
                    update_row_state(ident, runtime_row_updates(local))
                latest_stored = state()
                local = latest_stored.setdefault("rows", {}).setdefault(ident, {})
                status = local.get("status")
                already_has_live_order = bool(local.get("schwabOrderId"))
            if row["triggerHit"] and status not in blocked_statuses and not already_has_live_order:
                if mode == "live":
                    window_status = live_entry_window_status()
                    if not window_status["ok"]:
                        block_key = f"{window_status['reason']}|{window_status['localNow'][:16]}"
                        if local.get("lastLiveWindowBlockKey") != block_key:
                            local["lastLiveWindowBlockKey"] = block_key
                            append_event(ident, "warning", "Skipped live submit outside configured entry window.", window_status)
                        update_row_state(ident, runtime_row_updates(local))
                        continue
                local["status"] = "triggered"
                append_event(ident, "info", f"Trigger hit for {row['Ticker']} at {row.get('TriggerOperator')} {row.get('TriggerPrice')}", {"mode": mode})
                if mode == "paper":
                    local["status"] = "paper_submitted"
                    append_event(ident, "info", "Paper order staged; live submit is disabled by executionMode.", row["orderPlan"])
                else:
                    try:
                        live_preflight()
                        submit = submit_live_order(row, "initial")
                        local["status"] = "live_working" if submit.get("readbackConfirmed") else "live_submitted_unconfirmed"
                        local["schwabOrderId"] = submit.get("orderId", "")
                        local["schwabLocation"] = submit.get("location", "")
                        local["brokerStatus"] = submit.get("readbackStatus", "")
                        local["submittedPayload"] = submit.get("payload", {})
                        local["submittedPricing"] = submit.get("pricing", {})
                        local["submittedLimit"] = submitted_limit(submit)
                        local["submittedPhase"] = "initial"
                        local["submittedAt"] = utc_now()
                        local["cancelReplaceCount"] = 0
                        append_event(ident, "info", "Live order submitted to Schwab.", submit)
                    except Exception as exc:
                        local["status"] = "live_submit_failed"
                        append_event(ident, "error", f"Live submit failed: {exc}", row["orderPlan"])
                update_row_state(ident, runtime_row_updates(local))
        time.sleep(max(1, int(config().get("quotePollSeconds", 5))))


def monitor_loop():
    while runtime["monitor_desired"]:
        runtime["monitor_running"] = True
        try:
            monitor_loop_body()
        except Exception as exc:
            runtime["last_monitor_error"] = str(exc)
            runtime["last_order_error"] = f"Monitor cycle failed unexpectedly: {exc}"
            runtime["monitor_restart_count"] += 1
            if runtime["monitor_desired"]:
                time.sleep(max(1, int(config().get("quotePollSeconds", 5))))
    runtime["monitor_running"] = False
    runtime["thread"] = None


def reconcile_live_orders():
    stored = state()
    tracked = {
        row_id_value: row_state
        for row_id_value, row_state in stored.get("rows", {}).items()
        if row_state.get("schwabOrderId")
    }
    if not tracked:
        return
    try:
        lookup = fetch_recent_order_lookup()
    except Exception as exc:
        runtime["last_order_error"] = str(exc)
        return
    runtime["last_order_error"] = None
    for row_id_value, row_state in tracked.items():
        order_id = str(row_state.get("schwabOrderId"))
        broker = lookup.get(order_id)
        if not broker:
            continue
        broker, replacement_ids = resolve_replacement_chain(broker, lookup)
        broker_status = str(broker.get("status") or "")
        updates = {
            "brokerStatus": broker_status,
            "brokerEnteredTime": broker.get("enteredTime", ""),
            "filledQuantity": broker.get("filledQuantity", ""),
            "remainingQuantity": broker.get("remainingQuantity", ""),
        }
        resolved_order_id = str(broker.get("orderId") or order_id)
        if resolved_order_id != order_id:
            prior_ids = list(row_state.get("replacedOrderIds") or [])
            for replaced_id in replacement_ids:
                if replaced_id not in prior_ids:
                    prior_ids.append(replaced_id)
            updates["replacedOrderIds"] = prior_ids
            updates["schwabOrderId"] = resolved_order_id
        next_status = swing_status_from_broker(broker_status)
        if next_status and row_state.get("status") != next_status:
            updates["status"] = next_status
            updates["updatedAt"] = utc_now()
            update_row_state(row_id_value, updates)
            append_event(row_id_value, "info", f"Broker status is {broker_status}.", {"orderId": resolved_order_id, "replacedOrderIds": replacement_ids})
        else:
            update_row_state(row_id_value, updates)


def fetch_recent_order_lookup():
    base = config().get("tradingDashboardBaseUrl", "http://127.0.0.1:5080").rstrip("/")
    url = base + "/api/schwab/orders?" + urllib.parse.urlencode({"daysBack": "10", "maxResults": "3000"})
    with urllib.request.urlopen(url, timeout=12) as response:
        data = json.loads(response.read().decode("utf-8"))
    items = data.get("value", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        return {}
    return {
        str(item.get("orderId")): item
        for item in items
        if isinstance(item, dict) and item.get("orderId") is not None
    }


def confirm_submitted_order(order_id, attempts=6, delay_seconds=1):
    for _ in range(attempts):
        lookup = fetch_recent_order_lookup()
        order = lookup.get(str(order_id))
        if order:
            return order
        time.sleep(delay_seconds)
    return None


def replacement_signature(order):
    legs = []
    for leg in order.get("orderLegCollection") or []:
        instrument = leg.get("instrument") or {}
        legs.append((
            str(leg.get("instruction") or "").upper(),
            str(instrument.get("symbol") or "").strip().upper(),
            float(leg.get("quantity") or 0),
        ))
    return (
        str(order.get("accountNumber") or ""),
        str(order.get("orderType") or "").upper(),
        str(order.get("complexOrderStrategyType") or "").upper(),
        float(order.get("quantity") or 0),
        tuple(legs),
    )


def resolve_replacement_chain(order, lookup, max_gap_seconds=120):
    current = order
    replaced_ids = []
    visited = set()
    while str(current.get("status") or "").upper() == "REPLACED":
        current_id = str(current.get("orderId") or "")
        if not current_id or current_id in visited:
            break
        visited.add(current_id)
        close_time = parse_utc(current.get("closeTime"))
        if close_time is None:
            break
        signature = replacement_signature(current)
        candidates = []
        for candidate in lookup.values():
            candidate_id = str(candidate.get("orderId") or "")
            if not candidate_id or candidate_id in visited:
                continue
            if replacement_signature(candidate) != signature:
                continue
            entered_time = parse_utc(candidate.get("enteredTime"))
            if entered_time is None:
                continue
            gap_seconds = (entered_time - close_time).total_seconds()
            if -2 <= gap_seconds <= max_gap_seconds:
                candidates.append((abs(gap_seconds), entered_time, candidate))
        if not candidates:
            break
        candidates.sort(key=lambda item: (item[0], item[1]))
        replaced_ids.append(current_id)
        current = candidates[0][2]
    return current, replaced_ids


def swing_status_from_broker(status):
    text = (status or "").upper()
    if text in {"FILLED"}:
        return "filled_pending_oco"
    if text in {"CANCELED", "CANCELLED", "REJECTED", "EXPIRED", "REPLACED"}:
        return "broker_terminal"
    if text in {"WORKING", "PENDING_ACTIVATION", "QUEUED", "ACCEPTED", "AWAITING_CONDITION"}:
        return "live_working"
    if "PARTIAL" in text:
        return "partial_fill_review"
    return ""



def active_broker_status(status):
    text = str(status or "").upper()
    return text in {"WORKING", "PENDING_ACTIVATION", "QUEUED", "ACCEPTED", "AWAITING_CONDITION"}


def broker_order_leg_symbols(order):
    symbols = set()
    if not isinstance(order, dict):
        return symbols
    for leg in order.get("orderLegCollection") or []:
        if isinstance(leg, dict):
            instrument = leg.get("instrument") if isinstance(leg.get("instrument"), dict) else {}
            symbol = str(instrument.get("symbol") or "").upper()
            if symbol:
                symbols.add(symbol)
    for child in order.get("childOrderStrategies") or []:
        symbols.update(broker_order_leg_symbols(child))
    return symbols


def row_account_number(row):
    account = str(row.get("Account") or "")
    if account == "IRA":
        return "5682"
    if account == "Living Trust":
        return "9157"
    return ""


def order_account_matches_row(order, row):
    expected = row_account_number(row)
    if not expected:
        return True
    actual = str(order.get("accountNumber") or "")
    return actual.endswith(expected[-4:]) if actual else False


def parse_contract_label_parts(label):
    match = re.match(r"^([0-9.]+(?:/[0-9.]+)*)\s*([CP])\s+(\d{2})-(\d{2})$", str(label or "").strip(), re.I)
    if not match:
        return None
    year = dt.datetime.now().year % 100
    strikes = {round(float(value), 3) for value in match.group(1).split("/")}
    right = "CALL" if match.group(2).upper() == "C" else "PUT"
    exp = f"{year:02d}{match.group(3)}{match.group(4)}"
    return {"strikes": strikes, "right": right, "exp": exp}


def option_leg_signature(leg):
    instrument = leg.get("instrument") if isinstance(leg, dict) else {}
    if not isinstance(instrument, dict):
        return None
    right = str(instrument.get("putCall") or "").upper()
    symbol = str(instrument.get("symbol") or instrument.get("uniformSymbol") or "").upper().replace(" ", "")
    match = re.search(r"(\d{6})([CP])(\d{8})$", symbol)
    if not match:
        return None
    exp = match.group(1)
    if not right:
        right = "CALL" if match.group(2) == "C" else "PUT"
    strike = round(int(match.group(3)) / 1000.0, 3)
    underlying = str(instrument.get("underlyingSymbol") or "").upper()
    return {"underlying": underlying, "right": right, "exp": exp, "strike": strike}


def broker_option_order_matches_row(order, row):
    expected = parse_contract_label_parts(row.get("ContractLabel"))
    if not expected:
        return False
    ticker = str(row.get("Ticker") or "").upper()
    signatures = []
    for leg in order.get("orderLegCollection") or []:
        sig = option_leg_signature(leg)
        if sig:
            signatures.append(sig)
    if not signatures:
        return False
    if any(sig["underlying"] and sig["underlying"] != ticker for sig in signatures):
        return False
    if any(sig["right"] != expected["right"] or sig["exp"] != expected["exp"] for sig in signatures):
        return False
    strikes = {sig["strike"] for sig in signatures}
    return strikes == expected["strikes"]


def broker_order_matches_row(order, row):
    if not active_broker_status(order.get("status")):
        return False
    if not order_account_matches_row(order, row):
        return False
    ticker = str(row.get("Ticker") or "").upper()
    if not ticker:
        return False
    symbols = broker_order_leg_symbols(order)
    if not symbols:
        return False
    asset_type = str(row.get("AssetType") or "").lower()
    if asset_type == "stock":
        return ticker in symbols
    if asset_type == "option":
        return broker_option_order_matches_row(order, row)
    return False


def find_active_broker_order_for_row(row):
    lookup = fetch_recent_order_lookup()
    for order in lookup.values():
        if broker_order_matches_row(order, row):
            return order
    return None

def submit_live_order(row, phase):
    if not SUBMIT_PROJECT.exists():
        raise RuntimeError(f"Submit helper was not found: {SUBMIT_PROJECT}")
    require_live_entry_window()
    duplicate = find_active_broker_order_for_row(row)
    if duplicate:
        order_id = duplicate.get("orderId", "")
        status = duplicate.get("status", "")
        raise RuntimeError(f"Broker already has an active matching order for {row.get('Ticker')}: orderId={order_id}, status={status}")
    plan_dir = DATA_DIR / "live-submit-plans"
    plan_dir.mkdir(parents=True, exist_ok=True)
    safe_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", row["id"])[:140]
    plan_path = plan_dir / f"{int(time.time())}-{safe_id}.json"
    plan = {
        "rowId": row["id"],
        "account": row.get("Account"),
        "assetType": row.get("AssetType"),
        "ticker": row.get("Ticker"),
        "contractLabel": row.get("ContractLabel"),
        "structure": row.get("Structure"),
        "direction": row.get("Direction"),
        "quantity": int(float(row.get("Quantity") or 0)),
        "triggerPrice": float(row.get("TriggerPrice")),
        "pricePhase": phase,
    }
    save_json(plan_path, plan)
    completed = subprocess.run(
        submit_helper_command("submit-plan", str(plan_path)),
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=60,
        check=False)
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or completed.stdout).strip())
    result = parse_json_from_process_output(completed.stdout)
    if not result.get("accepted"):
        raise RuntimeError(f"Schwab did not accept order: {result}")
    order_id = str(result.get("orderId") or "")
    if not order_id:
        raise RuntimeError(f"Schwab accepted response did not include an order id: {result}")
    readback = confirm_submitted_order(order_id)
    result["readbackConfirmed"] = readback is not None
    if readback:
        result["readbackStatus"] = readback.get("status", "")
        result["readbackEnteredTime"] = readback.get("enteredTime", "")
    return result


def cancel_live_order(row, order_id):
    completed = subprocess.run(
        submit_helper_command(
            "cancel-order",
            str(row.get("Account") or ""),
            str(order_id)),
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=60,
        check=False)
    if completed.returncode != 0:
        raise RuntimeError((completed.stderr or completed.stdout).strip())
    result = parse_json_from_process_output(completed.stdout)
    if not result.get("accepted"):
        raise RuntimeError(f"Schwab did not accept cancel request: {result}")
    return result


def submit_helper_command(*arguments):
    if SUBMIT_DLL.exists():
        return ["dotnet", str(SUBMIT_DLL), *arguments]
    return ["dotnet", "run", "--project", str(SUBMIT_PROJECT), "--", *arguments]


def submitted_limit(submit_result):
    pricing = submit_result.get("pricing") if isinstance(submit_result, dict) else {}
    if not isinstance(pricing, dict):
        return ""
    value = pricing.get("submittedLimit")
    return "" if value is None else str(value)


def order_is_working(row_state):
    status = str(row_state.get("status") or "")
    broker = str(row_state.get("brokerStatus") or "").upper()
    if status in {"filled_pending_oco", "partial_fill_review", "broker_terminal", "live_replace_failed"}:
        return False
    if broker in {"FILLED", "CANCELED", "CANCELLED", "REJECTED", "EXPIRED"} or "PARTIAL" in broker:
        return False
    return status in {"live_working", "live_submitted_unconfirmed"}


def broker_status_terminal(status):
    return str(status or "").upper() in {
        "CANCELED", "CANCELLED", "REJECTED", "EXPIRED", "FILLED"
    }


def broker_status_stable_for_replace(status):
    text = str(status or "").upper()
    return broker_status_terminal(text) or "PARTIAL" in text


def wait_for_terminal_order(order_id, attempts=12, delay_seconds=0.25):
    latest = None
    for _ in range(attempts):
        latest = fetch_recent_order_lookup().get(str(order_id))
        if latest and broker_status_stable_for_replace(latest.get("status")):
            return latest
        time.sleep(delay_seconds)
    return latest


def maybe_replace_with_mark(row, row_state):
    cfg = config()
    if not cfg.get("enableCancelReplaceLadder", False):
        return False
    order_id = str(row_state.get("schwabOrderId") or "")
    if not order_id or not order_is_working(row_state):
        return False
    if str(row_state.get("submittedPhase") or "initial") == "mark":
        return False
    max_count = int(cfg.get("maxCancelReplaceCount", 1))
    if int(row_state.get("cancelReplaceCount") or 0) >= max_count:
        return False
    submitted_at = parse_utc(row_state.get("submittedAt") or row_state.get("updatedAt"))
    if submitted_at is None:
        return False
    age = (dt.datetime.now(dt.timezone.utc) - submitted_at).total_seconds()
    if age < int(cfg.get("bidPhaseSeconds", 60)):
        return False
    if not row.get("triggerHit"):
        append_event(row["id"], "warning", "Skipped mark replacement because the trigger is no longer valid.", {"orderId": order_id})
        return False
    window_status = live_entry_window_status()
    if not window_status["ok"]:
        append_event(row["id"], "warning", "Skipped mark replacement outside configured entry window.", {"orderId": order_id, **window_status})
        return False

    append_event(row["id"], "info", "Canceling initial live order before mark replacement.", {"orderId": order_id})
    cancel = cancel_live_order(row, order_id)
    terminal = wait_for_terminal_order(order_id)
    terminal_status = str((terminal or {}).get("status") or "").upper()
    if not terminal or not broker_status_stable_for_replace(terminal_status):
        row_state["status"] = "live_replace_blocked_cancel_unconfirmed"
        row_state["lastCancelResult"] = cancel
        row_state["lastCancelReplaceAt"] = utc_now()
        update_row_state(row["id"], row_state)
        append_event(row["id"], "error", "Replacement blocked because the original order did not reach a terminal broker state.", {"orderId": order_id, "brokerStatus": terminal_status or "UNAVAILABLE"})
        return False
    if terminal_status == "FILLED" or "PARTIAL" in terminal_status:
        row_state["status"] = "filled_pending_oco" if terminal_status == "FILLED" else "partial_fill_review"
        row_state["brokerStatus"] = terminal_status
        update_row_state(row["id"], row_state)
        append_event(row["id"], "warning", "Replacement suppressed because the original order filled during cancellation.", {"orderId": order_id, "brokerStatus": terminal_status})
        return False
    replaced = list(row_state.get("replacedOrderIds") or [])
    replaced.append(order_id)
    row_state["replacedOrderIds"] = replaced
    row_state["lastCancelResult"] = cancel
    row_state["lastCancelReplaceAt"] = utc_now()
    row_state["status"] = "live_replacing"
    update_row_state(row["id"], row_state)

    submit = submit_live_order(row, "mark")
    row_state.update({
        "status": "live_working" if submit.get("readbackConfirmed") else "live_submitted_unconfirmed",
        "schwabOrderId": submit.get("orderId", ""),
        "schwabLocation": submit.get("location", ""),
        "brokerStatus": submit.get("readbackStatus", ""),
        "submittedPayload": submit.get("payload", {}),
        "submittedPricing": submit.get("pricing", {}),
        "submittedLimit": submitted_limit(submit),
        "submittedPhase": "mark",
        "submittedAt": utc_now(),
        "cancelReplaceCount": int(row_state.get("cancelReplaceCount") or 0) + 1,
    })
    update_row_state(row["id"], row_state)
    append_event(row["id"], "info", "Replaced live order at mark pricing.", submit)
    return True


def start_monitor():
    if runtime["monitor_running"]:
        return
    if config().get("executionMode") == "live":
        live_preflight()
    runtime["monitor_desired"] = True
    runtime["monitor_running"] = True
    runtime["monitor_started_at"] = utc_now()
    thread = threading.Thread(target=monitor_loop, daemon=True)
    runtime["thread"] = thread
    thread.start()


def stop_monitor():
    runtime["monitor_desired"] = False
    runtime["monitor_running"] = False


def live_preflight():
    cfg = config()
    issues = []
    warnings = []
    if not SUBMIT_PROJECT.exists():
        issues.append(f"Submit helper missing: {SUBMIT_PROJECT}")
    base = config().get("tradingDashboardBaseUrl", "http://127.0.0.1:5080").rstrip("/")
    token_expires = None
    token_required_through = None
    try:
        refresh_request = urllib.request.Request(
            base + "/api/schwab/refresh-token",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST")
        with urllib.request.urlopen(refresh_request, timeout=12) as response:
            status = json.loads(response.read().decode("utf-8"))
        if not status.get("configured"):
            issues.append("Schwab is not configured in TradingDashboard.")
        if not status.get("connected"):
            issues.append("Schwab is not connected in TradingDashboard.")
        if status.get("accessTokenExpired"):
            issues.append("Schwab access token is expired.")
        token_expires = parse_utc(status.get("accessTokenExpiresUtc"))
        min_valid_minutes = int(cfg.get("liveTokenMinValidMinutes", 20))
        token_required_through = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=min_valid_minutes)
        if token_expires and token_expires < token_required_through:
            issues.append(
                "Schwab access token could not be refreshed far enough for live entry: "
                f"expires={token_expires.isoformat()}, requiredThrough={token_required_through.isoformat()}"
            )
        if not status.get("orderCapability"):
            warnings.append(
                "TradingDashboard Schwab order capability is not enabled. "
                "Swing Manager direct Schwab submit remains allowed because it uses the shared OAuth token, "
                "account-number lookup, and Schwab API submit helper instead of TradingDashboard order routes."
            )
    except Exception as exc:
        issues.append(f"Could not refresh/read Schwab status: {exc}")
    try:
        with urllib.request.urlopen(base + "/api/schwab/account-numbers", timeout=8) as response:
            accounts = json.loads(response.read().decode("utf-8"))
        text = json.dumps(accounts)
        if "5682" not in text:
            issues.append("IRA account ending 5682 was not found.")
        if "9157" not in text:
            issues.append("Living Trust account ending 9157 was not found.")
    except Exception as exc:
        issues.append(f"Could not resolve Schwab account numbers: {exc}")
    worklist = load_worklist_review()
    manual_oco_mode = bool(cfg.get("allowLiveEntriesWithManualOco", False))
    if not worklist.get("worklistPath"):
        message = "OCO/stop worklist has not been built from the latest JSON/preflight."
        if manual_oco_mode:
            warnings.append(message)
        else:
            issues.append(message)
    elif int(worklist.get("blockingCount") or 0) > 0:
        message = f"OCO/stop worklist has {worklist.get('blockingCount')} unresolved protection rows."
        if manual_oco_mode:
            warnings.append(message + " New entries may be submitted, but protective OCO follow-up is manual.")
        else:
            issues.append(message)
    runtime["last_live_preflight"] = {
        "checkedAt": utc_now(),
        "ok": not issues,
        "issues": issues,
        "warnings": warnings,
        "executionMode": cfg.get("executionMode", "paper"),
        "manualOcoMode": manual_oco_mode,
        "tokenExpiresUtc": status.get("accessTokenExpiresUtc") if "status" in locals() else "",
        "tokenRequiredThroughUtc": token_required_through.isoformat() if token_required_through else "",
        "dashboardOrderCapability": bool(status.get("orderCapability")) if "status" in locals() else False,
        "cancelReplaceLadder": bool(cfg.get("enableCancelReplaceLadder", False)),
        "bidPhaseSeconds": int(cfg.get("bidPhaseSeconds", 60)),
    }
    if issues:
        raise RuntimeError("Live preflight failed: " + "; ".join(issues))


class Handler(BaseHTTPRequestHandler):
    server_version = "SwingManagerPending/0.1"

    def log_message(self, fmt, *args):
        return

    def send_json(self, value, status=200):
        body = json.dumps(value, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        last_error = None
        for encoding in ("utf-8", "utf-8-sig", "cp1252"):
            try:
                return json.loads(raw.decode(encoding))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                last_error = exc
        raise ValueError(f"Could not decode JSON request body: {last_error}")

    def serve_file(self, path, content_type):
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            return self.serve_file(WEB_DIR / "index.html", "text/html; charset=utf-8")
        if parsed.path == "/app.js":
            return self.serve_file(WEB_DIR / "app.js", "application/javascript; charset=utf-8")
        if parsed.path == "/styles.css":
            return self.serve_file(WEB_DIR / "styles.css", "text/css; charset=utf-8")
        if parsed.path == "/api/pending":
            rows, queue_path = load_pending_rows()
            return self.send_json({
                "queuePath": queue_path,
                "config": config(),
                "runtime": {
                    "monitorRunning": runtime["monitor_running"],
                    "monitorDesired": runtime.get("monitor_desired"),
                    "monitorStartedAt": runtime["monitor_started_at"],
                    "monitorRestartCount": runtime.get("monitor_restart_count", 0),
                    "lastMonitorError": runtime.get("last_monitor_error"),
                    "lastQuoteError": runtime["last_quote_error"],
                    "lastQuoteRefreshAt": runtime.get("last_quote_refresh_at"),
                    "lastQuoteFreshness": runtime.get("last_quote_freshness"),
                    "lastOrderError": runtime.get("last_order_error"),
                    "lastLivePreflight": runtime.get("last_live_preflight"),
                    "lastTokenRefreshAt": runtime.get("last_token_refresh_at"),
                    "lastTokenRefreshError": runtime.get("last_token_refresh_error"),
                    "quoteCount": len(runtime["quotes"]),
                },
                "rows": rows,
            })
        if parsed.path == "/api/refresh-quotes":
            refresh_quotes()
            rows, queue_path = load_pending_rows()
            return self.send_json({"queuePath": queue_path, "rows": rows, "lastQuoteError": runtime["last_quote_error"]})
        if parsed.path == "/api/workflow":
            return self.send_json(workflow_status())
        if parsed.path == "/api/oco":
            return self.send_json(load_oco_review())
        if parsed.path == "/api/oco/desktop-batch":
            path, batch = load_desktop_oco_batch()
            return self.send_json({"path": str(path) if path else None, "batch": batch})
        return self.send_json({"error": "not found"}, status=404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/pending/state":
            body = self.read_json()
            ident = body.get("id")
            if not ident:
                return self.send_json({"error": "id is required"}, status=400)
            updates = {}
            for key in ("enabled", "deleted", "status"):
                if key in body:
                    updates[key] = body[key]
            updates["updatedAt"] = utc_now()
            update_row_state(ident, updates)
            return self.send_json({"ok": True})
        if parsed.path == "/api/nightly/upload-json":
            try:
                body = self.read_json()
                saved_path, parsed_json = save_uploaded_json(body.get("filename"), body.get("content"))
                capture_tos = parse_bool(body.get("captureTos"))
                save_workflow_status({
                    "lastUploadPath": str(saved_path),
                    "lastUploadScanDate": parsed_json.get("scan_date", ""),
                    "lastUploadAt": utc_now(),
                    "lastRunOk": None,
                })
                status = run_nightly_update(saved_path, capture_tos=capture_tos)
                return self.send_json({"ok": True, "status": status})
            except Exception as exc:
                save_workflow_status({"lastRunOk": False, "lastRunError": str(exc)})
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/nightly/preflight":
            try:
                body = self.read_json()
                source = body.get("sourcePath") or workflow_status().get("lastUploadPath")
                if not source:
                    return self.send_json({"ok": False, "error": "Upload a JSON file before running preflight."}, status=400)
                capture_tos = True if "captureTos" not in body else parse_bool(body.get("captureTos"))
                status = run_nightly_update(Path(source), capture_tos=capture_tos)
                return self.send_json({"ok": True, "status": status})
            except Exception as exc:
                save_workflow_status({"lastRunOk": False, "lastRunError": str(exc)})
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/nightly/reconcile":
            try:
                body = self.read_json()
                source = body.get("sourcePath") or workflow_status().get("lastUploadPath") or workflow_status().get("sourceJson")
                if not source:
                    return self.send_json({"ok": False, "error": "Upload a JSON file before building the OCO worklist."}, status=400)
                status = run_nightly_reconciliation(Path(source))
                return self.send_json({"ok": True, "status": status})
            except Exception as exc:
                save_workflow_status({"lastReconcileOk": False, "lastReconcileError": str(exc)})
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/oco/desktop-batch/plan":
            try:
                body = self.read_json()
                plan = run_desktop_oco_batch_plan(body)
                return self.send_json({"ok": True, "plan": plan, "status": workflow_status()})
            except Exception as exc:
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/oco/desktop-workflow":
            try:
                body = self.read_json()
                result = run_desktop_oco_workflow(body)
                return self.send_json({"ok": True, "result": result, "status": workflow_status()})
            except Exception as exc:
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/oco/desktop-workflow/next":
            try:
                body = self.read_json()
                result = run_next_desktop_oco_workflow(body)
                return self.send_json({"ok": True, "result": result, "status": workflow_status()})
            except Exception as exc:
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/oco/prepare-account":
            try:
                body = self.read_json()
                result = prepare_tos_account_batch(body)
                return self.send_json({"ok": True, "result": result, "status": workflow_status()})
            except Exception as exc:
                return self.send_json({"ok": False, "error": str(exc), "status": workflow_status()}, status=500)
        if parsed.path == "/api/monitor/start":
            try:
                start_monitor()
                return self.send_json({"ok": True, "monitorRunning": True, "preflight": runtime.get("last_live_preflight")})
            except Exception as exc:
                return self.send_json({"ok": False, "error": str(exc), "preflight": runtime.get("last_live_preflight")}, status=409)
        if parsed.path == "/api/monitor/stop":
            stop_monitor()
            return self.send_json({"ok": True, "monitorRunning": False})
        return self.send_json({"error": "not found"}, status=404)


def main():
    ensure_dirs()
    host = os.environ.get("SWING_MANAGER_HOST", "127.0.0.1")
    port = int(os.environ.get("SWING_MANAGER_PORT", "8765"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"Swing Manager pending server listening on http://{host}:{port}")
    if parse_bool(os.environ.get("SWING_MANAGER_AUTO_START_MONITOR", "false")):
        start_monitor()
        print("Swing Manager monitor started automatically after live preflight.")
    server.serve_forever()


if __name__ == "__main__":
    main()
