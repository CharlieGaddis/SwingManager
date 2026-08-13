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
  return `
    <div class="workflow-cards">
      <div><span>Run State</span><strong>${runState}</strong></div>
      <div><span>JSON</span><strong title="${status.sourceJson || status.lastUploadPath || ""}">${pathLeaf(status.sourceJson || status.lastUploadPath) || "none"}</strong></div>
      <div><span>Pending Entries</span><strong>${status.pendingCount ?? 0}</strong></div>
      <div><span>OCO Review</span><strong>${counts || "none"}</strong></div>
    </div>
    ${status.lastRunError ? `<div class="workflow-error">${status.lastRunError}</div>` : ""}
    <div class="workflow-files">
      <span title="${status.actionQueuePath || ""}">Queue: ${pathLeaf(status.actionQueuePath) || "none"}</span>
      <span title="${status.ocoReconciliationPath || ""}">TOS: ${pathLeaf(status.ocoReconciliationPath) || "none"}</span>
      <span title="${status.ocoUpdateQueuePath || ""}">Updates: ${pathLeaf(status.ocoUpdateQueuePath) || "none"}</span>
    </div>`;
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
async function loadOcoReview() {
  if (!ocoReviewEl) return;
  try {
    const response = await fetch("/api/oco");
    const data = await response.json();
    const counts = Object.entries(data.counts || {}).map(([name, count]) => `${name}: ${count}`).join(" | ");
    const rows = data.reconciliation || [];
    const updates = data.jsonUpdates || [];
    ocoReviewEl.innerHTML = `
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
      </div>`;
  } catch (error) {
    ocoReviewEl.textContent = `OCO review unavailable: ${error}`;
  }
}

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

themeBtn.addEventListener("click", () => {
  const current = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
  setTheme(current === "dark" ? "light" : "dark");
});

setTheme(localStorage.getItem("swingTheme") || "light");
load();
setInterval(load, 5000);



