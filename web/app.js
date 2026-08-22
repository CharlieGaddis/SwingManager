const accountsEl = document.getElementById("accounts");
const queuePathEl = document.getElementById("queuePath");
const executionModeEl = document.getElementById("executionMode");
const monitorStateEl = document.getElementById("monitorState");
const quoteStateEl = document.getElementById("quoteState");
const refreshBtn = document.getElementById("refreshBtn");
const startBtn = document.getElementById("startBtn");
const stopBtn = document.getElementById("stopBtn");
const themeBtn = document.getElementById("themeBtn");
const ocoReviewEl = document.getElementById("ocoReview");
const workflowStatusEl = document.getElementById("workflowStatus");
const jsonFileEl = document.getElementById("jsonFile");
const captureTosOnUploadEl = document.getElementById("captureTosOnUpload");
const uploadJsonBtn = document.getElementById("uploadJsonBtn");
const runPreflightBtn = document.getElementById("runPreflightBtn");
const buildWorklistBtn = document.getElementById("buildWorklistBtn");

function fmt(value, places = 2) {
  const n = Number(value);
  if (!Number.isFinite(n)) return "";
  return n.toFixed(places);
}

function money(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return "";
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function quote(row, key) {
  const q = row.lastQuote || {};
  const inner = q.quote || {};
  return q[key] ?? inner[key] ?? "";
}

function quoteValue(row, keys) {
  for (const key of keys) {
    const value = quote(row, key);
    if (value !== "" && value !== null && value !== undefined) return value;
  }
  return "";
}

function statusClass(row) {
  if (row.triggerHit && !row.schwabOrderId && !row.status?.startsWith("live_")) return "status hit";
  return `status ${row.status || "armed"}`;
}

function distanceText(row) {
  const value = Number(row.distance);
  if (!Number.isFinite(value)) return "";
  return fmt(value, 2);
}

async function updateState(id, patch) {
  await fetch("/api/pending/state", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id, ...patch }),
  });
  await load();
}

function rowHtml(row) {
  const label = row.AssetType === "stock" ? row.Ticker : `${row.Ticker} ${row.ContractLabel}`;
  const mark = quoteValue(row, ["mark", "markPrice", "lastPrice", "last", "regularMarketLastPrice"]);
  const isOption = row.AssetType === "option";
  const next = row.AssetType === "stock"
    ? `Buy ${row.Quantity} at bid, then mark`
    : `${row.Structure} at bid-side, then mark`;
  const statusText = row.schwabOrderId || row.status ? (row.status || "live submitted") : (row.triggerHit ? "trigger hit" : "armed");
  return `
    <tr>
      <td><input type="checkbox" data-action="enabled" data-id="${row.id}" ${row.enabled ? "checked" : ""}></td>
      <td><button class="danger" data-action="delete" data-id="${row.id}" type="button">Delete</button></td>
      <td title="${label}">${label}</td>
      <td>${row.Structure || ""}</td>
      <td class="num">${row.TriggerOperator} ${money(row.TriggerPrice)}</td>
      <td class="num">${money(mark)}</td>
      <td class="num">${distanceText(row)}</td>
      <td class="num">${row.Quantity || ""}</td>
      <td class="num">${isOption ? "" : money(row.MaxCapital)}</td>
      <td class="num">${money(row.EstimatedCost)}</td>
      <td><span class="${statusClass(row)}">${statusText}</span></td>
      <td title="${row.schwabOrderId || ""}">${row.schwabOrderId || ""}</td>
      <td title="${row.brokerStatus || ""}">${row.brokerStatus || ""}</td>
      <td>${row.filledQuantity || ""}</td>
      <td>${row.submittedPhase || ""}</td>
      <td class="num">${money(row.submittedLimit)}</td>
      <td class="num">${row.cancelReplaceCount || ""}</td>
      <td title="${next}">${next}</td>
      <td title="${row.lastEvent || ""}" class="muted">${row.lastEvent || ""}</td>
    </tr>`;
}

function accountHtml(account, rows) {
  return `
    <section class="account">
      <h2>${account} <span class="muted">${rows.length} pending</span></h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th style="width:56px">Live</th>
              <th style="width:76px">Remove</th>
              <th style="width:170px">Order</th>
              <th style="width:150px">Structure</th>
              <th style="width:110px">Trigger</th>
              <th style="width:92px" class="num">Mark</th>
              <th style="width:96px" class="num">Distance</th>
              <th style="width:70px" class="num">Qty</th>
              <th style="width:100px" class="num">Stock Cap</th>
              <th style="width:110px" class="num">Est.</th>
              <th style="width:130px">Status</th>
              <th style="width:132px">Order ID</th>
              <th style="width:128px">Broker</th>
              <th style="width:72px">Filled</th>
              <th style="width:86px">Phase</th>
              <th style="width:86px" class="num">Limit</th>
              <th style="width:76px" class="num">Repl.</th>
              <th style="width:180px">Next Action</th>
              <th style="width:240px">Last Event</th>
            </tr>
          </thead>
          <tbody>${rows.map(rowHtml).join("")}</tbody>
        </table>
      </div>
    </section>`;
}


function ocoStatusClass(status) {
  if (status === "MATCHED_EXPECTED_LEVELS") return "oco-status ok";
  if (status === "NOT_VISIBLE_IN_CURRENT_VIEW") return "oco-status missing";
  if ((status || "").startsWith("REVIEW")) return "oco-status review";
  return "oco-status";
}

function apiWorksheetStatusClass(status) {
  if (status === "API_CONFIRMED_STRUCTURE_MANUAL_VERIFY_TARGETS") return "oco-status review";
  if (status === "MISSING_PROTECTION" || status === "API_TARGET_FOUND_STOP_MISSING") return "oco-status missing";
  if (status === "API_CONFIRMED_STOP_ONLY" || status === "API_STRUCTURE_REVIEW") return "oco-status review";
  return "oco-status";
}

function apiWorksheetRowHtml(row) {
  return `
    <tr>
      <td>${row.Account || ""}</td>
      <td>${row.Ticker || ""}</td>
      <td title="${row.ContractLabel || ""}">${row.ContractLabel || ""}</td>
      <td>${row.Portfolio || ""}</td>
      <td class="num">${money(row.ExpectedStop)}</td>
      <td class="num">${money(row.ExpectedT1)}</td>
      <td class="num">${money(row.ExpectedT2)}</td>
      <td class="num">${row.ApiWorkingChildRows || ""}</td>
      <td class="num">${row.ApiStopChildren || ""}</td>
      <td class="num">${row.ApiTargetChildren || ""}</td>
      <td title="${row.ApiParentOcoIds || ""}">${row.ApiParentOcoIds || ""}</td>
      <td title="${row.ApiStopPrices || ""}">${row.ApiStopPrices || ""}</td>
      <td><span class="${apiWorksheetStatusClass(row.WorksheetStatus)}">${row.WorksheetStatus || ""}</span></td>
      <td title="${row.NextAction || ""}">${row.NextAction || ""}</td>
    </tr>`;
}

function ocoRowHtml(row) {
  return `
    <tr>
      <td>${row.Account || ""}</td>
      <td>${row.Ticker || ""}</td>
      <td title="${row.ContractLabel || ""}">${row.ContractLabel || ""}</td>
      <td class="num">${money(row.ExpectedStop)}</td>
      <td class="num">${money(row.ExpectedT1)}</td>
      <td class="num">${money(row.ExpectedT2)}</td>
      <td class="num">${row.VisibleWorkingCloseRows || ""}</td>
      <td>${row.VisibleStopsBelow || ""}</td>
      <td>${row.VisibleTargetsAbove || ""}</td>
      <td><span class="${ocoStatusClass(row.ReconcileStatus)}">${row.ReconcileStatus || ""}</span></td>
    </tr>`;
}

function desktopOcoItemHtml(item) {
  const ready = item.ReadyForDesktopAutomation === true && item.AccountVerified === true;
  const disabled = ready ? "" : " disabled";
  const blockedTitle = ready ? "" : " title=\"Prepare the matching TOS account and rebuild/verify the batch before running automation.\"";
  return `
    <tr>
      <td class="workflow-inline-actions"><button type="button" data-action="plan-desktop-oco" data-symbol="${item.Symbol || ""}" data-phase="${item.Phase || ""}" data-oco-id="${item.OcoId || ""}" data-replacing-order-id="${item.ReplacingOrderId || ""}"${disabled}${blockedTitle}>Plan</button><button type="button" data-action="preview-desktop-oco" data-symbol="${item.Symbol || ""}" data-phase="${item.Phase || ""}" data-oco-id="${item.OcoId || ""}" data-replacing-order-id="${item.ReplacingOrderId || ""}"${disabled}${blockedTitle}>Preview</button><button type="button" data-action="send-desktop-oco" data-symbol="${item.Symbol || ""}" data-phase="${item.Phase || ""}" data-oco-id="${item.OcoId || ""}" data-replacing-order-id="${item.ReplacingOrderId || ""}"${disabled}${blockedTitle}>Final Send</button></td>
      <td>${item.TargetAccountAlias || item.CurrentTosAccountAlias || ""}</td>
      <td title="${item.InstrumentLabel || ""}">${item.Symbol || ""} ${item.InstrumentLabel || ""}</td>
      <td>${item.Phase || ""}</td>
      <td title="${item.OcoId || ""}">${item.OcoId || ""}</td>
      <td title="${item.ReplacingOrderId || ""}">${item.ReplacingOrderId || ""}</td>
      <td class="num">${money(item.CurrentThreshold)}</td>
      <td class="num">${money(item.ExpectedThreshold)}</td>
      <td class="num">${money(item.Delta)}</td>
      <td>${ready ? (item.SnapshotStatus || "Ready") : (item.AccountContextSource || "Not verified")}</td>
    </tr>`;
}
function jsonUpdateHtml(row) {
  return `
    <tr>
      <td>${row.Account || ""}</td>
      <td>${row.Ticker || ""}</td>
      <td title="${row.ContractLabel || ""}">${row.ContractLabel || ""}</td>
      <td class="num">${money(row.Stop)}</td>
      <td class="num">${money(row.T1)}</td>
      <td class="num">${money(row.T2)}</td>
      <td colspan="4" title="${row.ChangeNote || ""}">${row.ChangeNote || ""}</td>
    </tr>`;
}


function pathLeaf(path) {
  if (!path) return "";
  return String(path).split(/[\\/]/).pop();
}

function workflowStatusHtml(status) {
  const ok = status.lastRunOk;
  const runState = ok === true ? "Ready" : ok === false ? "Needs review" : "Not run";
  const counts = Object.entries(status.ocoCounts || {}).map(([name, count]) => `${name}: ${count}`).join(" | ");
  const worklistCounts = Object.entries(status.worklistCounts || {}).map(([name, count]) => `${name}: ${count}`).join(" | ");
  return `
    <div class="workflow-cards">
      <div><span>Run State</span><strong>${runState}</strong></div>
      <div><span>JSON</span><strong title="${status.sourceJson || status.lastUploadPath || ""}">${pathLeaf(status.sourceJson || status.lastUploadPath) || "none"}</strong></div>
      <div><span>Pending Entries</span><strong>${status.pendingCount ?? 0}</strong></div>
      <div><span>OCO Review</span><strong>${counts || "none"}</strong></div>
      <div><span>OCO Worklist</span><strong>${status.worklistBlockingCount ?? 0} blockers / ${status.ocoUpdateLevelCount ?? 0} levels</strong></div>
      <div><span>Desktop OCO Batch</span><strong>${status.desktopOcoBatchReadyCount ?? 0} ready / ${status.desktopOcoBatchUpdateCount ?? 0} updates</strong></div>
    </div>
    ${status.lastRunError ? `<div class="workflow-error">${status.lastRunError}</div>` : ""}
    <div class="workflow-files">
      <span title="${status.actionQueuePath || ""}">Queue: ${pathLeaf(status.actionQueuePath) || "none"}</span>
      <span title="${status.ocoReconciliationPath || ""}">TOS: ${pathLeaf(status.ocoReconciliationPath) || "none"}</span>
      <span title="${status.ocoUpdateQueuePath || ""}">Updates: ${pathLeaf(status.ocoUpdateQueuePath) || "none"}</span>
      <span title="${status.worklistPath || ""}">Worklist: ${pathLeaf(status.worklistPath) || "none"}</span>
      <span title="${status.ocoUpdateLevelsPath || ""}">Levels: ${pathLeaf(status.ocoUpdateLevelsPath) || "none"}</span>
      <span title="${status.desktopOcoBatchPath || ""}">Desktop batch: ${pathLeaf(status.desktopOcoBatchPath) || "none"}</span>
    </div>
    ${worklistCounts ? `<div class="workflow-files">Worklist counts: ${worklistCounts}</div>` : ""}`;
}

async function loadWorkflowStatus() {
  if (!workflowStatusEl) return;
  try {
    const response = await fetch("/api/workflow");
    const status = await response.json();
    workflowStatusEl.innerHTML = workflowStatusHtml(status);
  } catch (error) {
    workflowStatusEl.textContent = `Workflow status unavailable: ${error}`;
  }
}

function readFileText(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(reader.error || new Error("Could not read file."));
    reader.readAsText(file);
  });
}

async function uploadJsonAndBuildQueue() {
  const file = jsonFileEl?.files?.[0];
  if (!file) {
    alert("Choose a Squeeze JSON file first.");
    return;
  }
  uploadJsonBtn.disabled = true;
  runPreflightBtn.disabled = true;
  workflowStatusEl.textContent = "Uploading JSON and building queue...";
  try {
    const content = await readFileText(file);
    const response = await fetch("/api/nightly/upload-json", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: file.name, content, captureTos: captureTosOnUploadEl.checked }),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || "Upload workflow failed.");
    await load();
  } catch (error) {
    workflowStatusEl.innerHTML = `<div class="workflow-error">${error.message || error}</div>`;
  } finally {
    uploadJsonBtn.disabled = false;
    runPreflightBtn.disabled = false;
  }
}

async function runTosPreflight() {
  runPreflightBtn.disabled = true;
  uploadJsonBtn.disabled = true;
  workflowStatusEl.textContent = "Running TOS preflight...";
  try {
    const response = await fetch("/api/nightly/preflight", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ captureTos: true }),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || "Preflight failed.");
    await load();
  } catch (error) {
    workflowStatusEl.innerHTML = `<div class="workflow-error">${error.message || error}</div>`;
  } finally {
    runPreflightBtn.disabled = false;
    uploadJsonBtn.disabled = false;
  }
}
async function buildOcoWorklist() {
  buildWorklistBtn.disabled = true;
  runPreflightBtn.disabled = true;
  uploadJsonBtn.disabled = true;
  workflowStatusEl.textContent = "Building OCO/stop worklist...";
  try {
    const response = await fetch("/api/nightly/reconcile", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || "OCO worklist failed.");
    await load();
  } catch (error) {
    workflowStatusEl.innerHTML = `<div class="workflow-error">${error.message || error}</div>`;
  } finally {
    buildWorklistBtn.disabled = false;
    runPreflightBtn.disabled = false;
    uploadJsonBtn.disabled = false;
  }
}
async function loadOcoReview() {
  if (!ocoReviewEl) return;
  try {
    const response = await fetch("/api/oco");
    const data = await response.json();
    const counts = Object.entries(data.counts || {}).map(([name, count]) => `${name}: ${count}`).join(" | ");
    const apiRows = data.apiWorksheet || [];
    const rows = data.reconciliation || [];
    const updates = data.jsonUpdates || [];
    ocoReviewEl.innerHTML = `
      <h3>API OCO Worksheet</h3>
      <div class="oco-summary">${apiRows.length ? `${apiRows.length} expected active OCO rows from Schwab API` : "No Schwab API OCO worksheet loaded"}${data.apiWorksheetPath ? ` | ${pathLeaf(data.apiWorksheetPath)}` : ""}</div>
      <div class="table-wrap">
        <table class="oco-table api-worksheet-table">
          <thead>
            <tr>
              <th style="width:120px">Account</th>
              <th style="width:80px">Ticker</th>
              <th style="width:130px">Contract</th>
              <th style="width:90px">Type</th>
              <th style="width:80px" class="num">Stop</th>
              <th style="width:80px" class="num">T1</th>
              <th style="width:80px" class="num">T2</th>
              <th style="width:70px" class="num">Rows</th>
              <th style="width:70px" class="num">Stops</th>
              <th style="width:76px" class="num">Targets</th>
              <th style="width:160px">OCO IDs</th>
              <th style="width:120px">API Stop</th>
              <th style="width:270px">Worksheet Status</th>
              <th style="width:300px">Next Action</th>
            </tr>
          </thead>
          <tbody>${apiRows.map(apiWorksheetRowHtml).join("")}</tbody>
        </table>
      </div>
      <h3>TOS Visible-Order Check</h3>
      <div class="oco-summary">${counts || "No TOS reconciliation loaded"}</div>
      <div class="table-wrap">
        <table class="oco-table">
          <thead>
            <tr>
              <th style="width:120px">Account</th>
              <th style="width:80px">Ticker</th>
              <th style="width:130px">Contract</th>
              <th style="width:80px" class="num">Stop</th>
              <th style="width:80px" class="num">T1</th>
              <th style="width:80px" class="num">T2</th>
              <th style="width:72px" class="num">Visible</th>
              <th style="width:120px">Stops</th>
              <th style="width:150px">Targets</th>
              <th style="width:190px">Status</th>
            </tr>
          </thead>
          <tbody>${rows.map(ocoRowHtml).join("")}</tbody>
        </table>
      </div>
      <h3>JSON OCO Changes</h3>
      <div class="table-wrap">
        <table class="oco-table">
          <thead>
            <tr>
              <th style="width:120px">Account</th>
              <th style="width:80px">Ticker</th>
              <th style="width:130px">Contract</th>
              <th style="width:80px" class="num">Stop</th>
              <th style="width:80px" class="num">T1</th>
              <th style="width:80px" class="num">T2</th>
              <th>Change</th>
            </tr>
          </thead>
          <tbody>${updates.map(jsonUpdateHtml).join("")}</tbody>
        </table>
      </div>
      <h3>Desktop OCO Updates</h3>
      <div class="oco-summary desktop-oco-head">
        <span>${data.desktopBatch?.readyCount || 0} ready / ${data.desktopBatch?.updateCount || 0} updates, target ${data.desktopBatch?.targetAccount?.Alias || "current"} ${data.desktopBatch?.targetAccount?.Ending || ""}, TOS account ${data.desktopBatch?.currentTosAccount?.Alias || "unknown"} ${data.desktopBatch?.currentTosAccount?.Ending || ""}</span>
        <span class="workflow-inline-actions">
          <button type="button" data-action="prepare-account-oco" data-account="Living Trust">Prepare Living Trust</button>
          <button type="button" data-action="prepare-account-oco" data-account="IRA">Prepare IRA</button>
          <button type="button" data-action="preview-next-desktop-oco">Run Next Preview</button>
          <button type="button" data-action="send-next-desktop-oco">Run Next Final Send</button>
        </span>
      </div>
      <div id="desktopOcoPlan" class="workflow-files"></div>
      <div class="table-wrap">
        <table class="oco-table">
          <thead>
            <tr>
              <th style="width:210px">Action</th>
              <th style="width:110px">Account</th>
              <th style="width:180px">Order</th>
              <th style="width:70px">Phase</th>
              <th style="width:132px">OCO ID</th>
              <th style="width:132px">Replacing</th>
              <th style="width:90px" class="num">Current</th>
              <th style="width:90px" class="num">Expected</th>
              <th style="width:80px" class="num">Delta</th>
              <th style="width:100px">Status</th>
            </tr>
          </thead>
          <tbody>${(data.desktopBatch?.updateItems || data.desktopBatch?.readyItems || []).map(desktopOcoItemHtml).join("")}</tbody>
        </table>
      </div>`;
  } catch (error) {
    ocoReviewEl.textContent = `OCO review unavailable: ${error}`;
  }
}

async function prepareDesktopOcoAccount(target) {
  const planEl = document.getElementById("desktopOcoPlan");
  const account = target.dataset.account;
  if (planEl) planEl.textContent = `Preparing ${account} TOS batch...`;
  try {
    const response = await fetch("/api/oco/prepare-account", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ account }),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || `Could not prepare ${account}.`);
    if (planEl) {
      const status = data.status || {};
      planEl.textContent = `Prepared ${account}: ${status.desktopOcoBatchReadyCount || 0} ready / ${status.desktopOcoBatchUpdateCount || 0} updates.`;
    }
    await load();
  } catch (error) {
    if (planEl) planEl.innerHTML = `<span class="workflow-error">${error.message || error}</span>`;
  }
}

async function planDesktopOcoItem(target) {
  const planEl = document.getElementById("desktopOcoPlan");
  if (planEl) planEl.textContent = "Building desktop OCO plan...";
  const payload = {
    symbol: target.dataset.symbol,
    phase: target.dataset.phase,
    ocoId: target.dataset.ocoId,
    replacingOrderId: target.dataset.replacingOrderId,
  };
  try {
    const response = await fetch("/api/oco/desktop-batch/plan", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || "Desktop OCO plan failed.");
    const step = data.plan?.nextOperatorStep || {};
    if (planEl) {
      planEl.innerHTML = `Selected ${step.symbol || ""} ${step.phase || ""}: ${money(step.currentThreshold)} -> ${money(step.expectedThreshold)}. Command: <code>${step.applyCommand || ""}</code>`;
    }
  } catch (error) {
    if (planEl) planEl.innerHTML = `<span class="workflow-error">${error.message || error}</span>`;
  }
}


async function runDesktopOcoWorkflow(target, stage, allowFinalSend = false) {
  const planEl = document.getElementById("desktopOcoPlan");
  const payload = {
    symbol: target.dataset.symbol,
    phase: target.dataset.phase,
    ocoId: target.dataset.ocoId,
    replacingOrderId: target.dataset.replacingOrderId,
    stage,
    allowInput: true,
    allowFinalSend,
  };
  if (allowFinalSend) {
    const ok = confirm(`Final Send for ${payload.symbol} ${payload.phase} OCO ${payload.ocoId}?`);
    if (!ok) return;
  }
  if (planEl) planEl.textContent = `${stage} running for ${payload.symbol} ${payload.phase}...`;
  try {
    const response = await fetch("/api/oco/desktop-workflow", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || "Desktop OCO workflow failed.");
    const result = data.result || {};
    const condition = result.expectedConditionText || "";
    const errors = (result.errors || []).join("; ");
    if (planEl) {
      planEl.innerHTML = `<span>${stage} ${result.success ? "completed" : "finished with review"}: ${condition}</span>${errors ? ` <span class="workflow-error">${errors}</span>` : ""}`;
    }
    await loadWorkflowStatus();
  } catch (error) {
    if (planEl) planEl.innerHTML = `<span class="workflow-error">${error.message || error}</span>`;
  }
}

async function runNextDesktopOcoWorkflow(stage, allowFinalSend = false) {
  const planEl = document.getElementById("desktopOcoPlan");
  if (allowFinalSend) {
    const ok = confirm("Final Send for the next ready desktop OCO update?");
    if (!ok) return;
  }
  if (planEl) planEl.textContent = `${stage} running for next ready desktop OCO update...`;
  try {
    const response = await fetch("/api/oco/desktop-workflow/next", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ stage, allowInput: true, allowFinalSend }),
    });
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || "Next desktop OCO workflow failed.");
    const selected = data.result?.selected || {};
    const result = data.result?.result || data.result || {};
    const condition = result.expectedConditionText || result.message || "";
    if (planEl) {
      planEl.innerHTML = `<span>Next ${selected.symbol || ""} ${selected.phase || ""} ${stage} completed: ${condition}</span>`;
    }
    await load();
  } catch (error) {
    if (planEl) planEl.innerHTML = `<span class="workflow-error">${error.message || error}</span>`;
  }
}
ocoReviewEl?.addEventListener("click", async (event) => {
  const target = event.target;
  if (target?.dataset?.action === "plan-desktop-oco") {
    await planDesktopOcoItem(target);
  }
  if (target?.dataset?.action === "preview-desktop-oco") {
    await runDesktopOcoWorkflow(target, "RunToConfirmation", false);
  }
  if (target?.dataset?.action === "send-desktop-oco") {
    await runDesktopOcoWorkflow(target, "RunToFinalSend", true);
  }
  if (target?.dataset?.action === "preview-next-desktop-oco") {
    await runNextDesktopOcoWorkflow("RunToConfirmation", false);
  }
  if (target?.dataset?.action === "send-next-desktop-oco") {
    await runNextDesktopOcoWorkflow("RunToFinalSend", true);
  }
  if (target?.dataset?.action === "prepare-account-oco") {
    await prepareDesktopOcoAccount(target);
  }
});
async function load(path = "/api/pending") {
  const response = await fetch(path);
  const data = await response.json();
  queuePathEl.textContent = data.queuePath || "No queue found";
  executionModeEl.textContent = data.config?.executionMode || "paper";
  monitorStateEl.textContent = data.runtime?.monitorRunning ? "running" : "stopped";
  quoteStateEl.textContent = data.runtime?.lastQuoteError ? `error: ${data.runtime.lastQuoteError}` : `${data.runtime?.quoteCount || 0} symbols`;
  const preflight = data.runtime?.lastLivePreflight;
  if (preflight && !preflight.ok) {
    quoteStateEl.title = (preflight.issues || []).join("\n");
  } else {
    quoteStateEl.title = "";
  }
  const groups = new Map();
  for (const row of data.rows || []) {
    if (!groups.has(row.Account)) groups.set(row.Account, []);
    groups.get(row.Account).push(row);
  }
  accountsEl.innerHTML = [...groups.entries()].map(([account, rows]) => accountHtml(account, rows)).join("");
  await loadOcoReview();
  await loadWorkflowStatus();
}

accountsEl.addEventListener("change", async (event) => {
  const target = event.target;
  if (target.dataset.action === "enabled") {
    await updateState(target.dataset.id, { enabled: target.checked });
  }
});

accountsEl.addEventListener("click", async (event) => {
  const target = event.target;
  if (target.dataset.action === "delete") {
    await updateState(target.dataset.id, { deleted: true, enabled: false });
  }
});

refreshBtn.addEventListener("click", () => load("/api/refresh-quotes"));
startBtn.addEventListener("click", async () => {
  const response = await fetch("/api/monitor/start", { method: "POST" });
  if (!response.ok) {
    const data = await response.json();
    alert(data.error || "Monitor could not start.");
  }
  await load();
});
stopBtn.addEventListener("click", async () => {
  await fetch("/api/monitor/stop", { method: "POST" });
  await load();
});

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem("swingTheme", theme);
  themeBtn.textContent = theme === "dark" ? "Light Mode" : "Dark Mode";
}

uploadJsonBtn?.addEventListener("click", uploadJsonAndBuildQueue);
runPreflightBtn?.addEventListener("click", runTosPreflight);
buildWorklistBtn?.addEventListener("click", buildOcoWorklist);

themeBtn.addEventListener("click", () => {
  const current = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
  setTheme(current === "dark" ? "light" : "dark");
});

setTheme(localStorage.getItem("swingTheme") || "light");
load();
setInterval(load, 5000);
