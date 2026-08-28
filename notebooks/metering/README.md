# Sovereign Core — Metering Notebooks

**sovereign-core-metrics-aggregator** is a metrics aggregation service for Sovereign Core that exposes metering and usage data endpoints. It underpins the **Metering Usage** feature of Sovereign Core — the infrastructure responsible for tracking, collecting, and exposing software consumption data across the platform, enabling Managed Service Providers (MSPs) to bill Application Developers and Tenants for their usage.

This repository contains reference notebooks for fetching and visualising the metering data. They cover authentication, fetching raw, aggregated, and grouped usage records from the API, and producing **interactive Plotly visualisations**.

---

## Notebooks

| # | Notebook | Purpose |
|---|---|---|
| 1 | [`Fetch - Usage Data.ipynb`](Fetch%20-%20Usage%20Data.ipynb) | Authenticate and fetch raw + aggregated + grouped usage data from the API. Run this only when connecting to a live deployment. |
| 2 | [`Processing - Raw Usage Data.ipynb`](Processing%20-%20Raw%20Usage%20Data.ipynb) | Analyse raw usage records — scatter explorer, heatmap, stacked bars, instance activity, metering model distribution. |
| 3 | [`Processing - Aggregated Usage Data.ipynb`](Processing%20-%20Aggregated%20Usage%20Data.ipynb) | Analyse aggregated (time-bucketed) usage — synced multi-metric dashboard, KPI cards, rolling averages, heatmap, histograms, day-over-day change. |
| 4 | [`Processing - Grouped Usage Data.ipynb`](Processing%20-%20Grouped%20Usage%20Data.ipynb) | Analyse grouped aggregated usage — compare resource consumption across tenants, workspaces, or instances with multi-line trends, donut share, active vs idle, slope chart, and per-group stats. |
| 5 | [`Use Case - Telemetry.ipynb`](Use%20Case%20-%20Telemetry.ipynb) | Operational telemetry dashboard — KPI summary, resource usage trend, usage by group, heatmap, data quality + anomaly detection. |
| 6 | [`Use Case - Billing.ipynb`](Use%20Case%20-%20Billing.ipynb) | Billing use-case demonstration — four pricing models (PayGo, per-instance, contract, contract + overage) applied to real `api_calls` tenant data, with a cross-model cost comparison. |
| — | [`Notebook - Template.ipynb`](Notebook%20-%20Template.ipynb) | **Authoring template** — canonical structure, section conventions, and annotated examples for every notebook category. Read this before creating a new notebook. |

> All charts are fully interactive — hover for exact values, click legend items to toggle series, drag to zoom, double-click to reset.

---

## Sample Data

A sample dataset is included in the `data/` directory, covering the service and environment configured in `.env.template`. It spans three data types:

- **`data/raw/`** — raw per-event usage records across multiple time windows (last 24 h, 7 d, and 30 d)
- **`data/aggregated/`** — time-bucketed usage summaries (daily averages and sums per metric)
- **`data/grouped/`** — aggregated usage broken down by tenant, workspace, and instance

This data is ready to use as-is with the default template values — no API access or deployment required. To replace it with data from your own deployment, configure `.env` with your credentials and run [`Fetch - Usage Data.ipynb`](Fetch%20-%20Usage%20Data.ipynb), which will overwrite the relevant files under `data/` with fresh results.

---

## Quick Start

**To explore with the included sample data (no deployment needed):**

1. Install dependencies and set up a virtual environment (see [Setup](#setup)).
2. Launch Jupyter and open any Processing or Use Case notebook (notebooks 2–6).
3. Run all cells — no further configuration needed. The notebooks fall back to `.env.template` values if no `.env` file is present, and the template values already match the included sample data.

**To fetch data from a live deployment:**

1. Complete the setup steps below.
2. Copy `.env.template` to `.env` and fill in your credentials (see [Configuration](#configuration)).
3. Run [`Fetch - Usage Data.ipynb`](Fetch%20-%20Usage%20Data.ipynb) first — this writes fresh data to `data/`.
4. Then run the Processing and Use Case notebooks as normal.

---

## Prerequisites

- Python 3.10+
- `pip` and `venv` (both included with a standard Python installation)

---

## Setup

### 1. Create and activate a virtual environment

```bash
# Create the environment (only needed once)
python3 -m venv .venv

# Activate — macOS / Linux
source .venv/bin/activate

# Activate — Windows (Command Prompt)
.venv\Scripts\activate.bat

# Activate — Windows (PowerShell)
.venv\Scripts\Activate.ps1
```

You should see `(.venv)` prefixed in your shell prompt once activated.

### 2. Install dependencies

```bash
pip install jupyter pandas plotly requests python-dotenv ipywidgets
```

### 3. Configuration

The notebooks read configuration from a `.env` file. For the included sample data no changes are needed — the dummy values in `.env.template` already match. If a `.env` file is not present, the notebooks fall back to the template values automatically.

To connect to a live deployment, copy the template and fill in your values:

```bash
cp .env.template .env
```

**Required for `Fetch - Usage Data.ipynb` (live deployment):**

| Variable | Description |
|---|---|
| `APP_DOMAIN` | Cluster domain, e.g. `apps.my-cluster.cp.fyre.ibm.com` |
| `SERVICE_ID` | Catalog service ID to query, e.g. `cluster-as-a-service` |
| `TENANT_ID` | Tenant UUID for tenant-scoped fetch examples, or `all` |
| `IAM_ACCOUNT_TYPE` | `platform` (MSP), `<tenant-uuid>` (App Developer), or `global_account` (Internal) |
| `API_KEY` | API key for the chosen IAM account type |

**Required for Processing & Use Case notebooks (optional overrides):**

| Variable | Description |
|---|---|
| `RAW_DATA_PATH` | Override the raw data directory (optional) |
| `AGGREGATED_DATA_PATH` | Override the aggregated data directory (optional) |
| `GROUPED_DATA_PATH` | Override the grouped data directory (optional) |

> `.env` is **not** committed. Never put real credentials in `.env.template`.

If the `*_DATA_PATH` variables are not set, the notebooks derive the paths automatically from `APP_DOMAIN` and `SERVICE_ID`. To point at a specific directory explicitly:

```
RAW_DATA_PATH=data/raw/my-service
AGGREGATED_DATA_PATH=data/aggregated/my-service
GROUPED_DATA_PATH=data/grouped/my-service
```

---

## Running the Notebooks

### Option A — JupyterLab (recommended)

```bash
jupyter lab
```

Open each notebook from the file browser on the left.

### Option B — Classic Jupyter Notebook

```bash
jupyter notebook
```

### Option C — VS Code

Open any `.ipynb` file directly in VS Code and select the `.venv` Python kernel when prompted.

---

## Execution Order

```
# With sample data (Fetch not required)
2. Processing - Raw Usage Data.ipynb         ← reads data/raw/
3. Processing - Aggregated Usage Data.ipynb  ← reads data/aggregated/
4. Processing - Grouped Usage Data.ipynb     ← reads data/grouped/
5. Use Case - Telemetry.ipynb                ← reads all three data dirs
6. Use Case - Billing.ipynb                  ← reads data/grouped/

# With a live deployment (run Fetch first)
1. Fetch - Usage Data.ipynb                  ← fetches from API, writes to data/
2–6. (same as above)
```

In each notebook run all cells top-to-bottom: **Run → Run All Cells** (or `Shift+Enter` cell by cell).

---

## Project Structure

```
.
├── Fetch - Usage Data.ipynb                  # Fetch from API (live deployments only)
├── Processing - Raw Usage Data.ipynb         # Raw usage charts
├── Processing - Aggregated Usage Data.ipynb  # Aggregated usage charts
├── Processing - Grouped Usage Data.ipynb     # Grouped usage charts
├── Use Case - Telemetry.ipynb                # Telemetry dashboard
├── Use Case - Billing.ipynb                  # Billing models
├── Notebook - Template.ipynb                 # Authoring reference
├── .env.template                             # Environment variable template (safe to commit)
├── .env                                      # Your local credentials (not committed)
├── data/
│   ├── raw/          # Raw usage JSON — included as sample data, overwritten by Fetch
│   ├── aggregated/   # Aggregated usage JSON — included as sample data, overwritten by Fetch
│   └── grouped/      # Grouped usage JSON — included as sample data, overwritten by Fetch
└── .gitignore
```

---

## Authoring New Notebooks

Use **[`Notebook - Template.ipynb`](Notebook%20-%20Template.ipynb)** as the starting point whenever adding a new notebook to this suite.

The template defines:

- **Naming convention** — `[Category] - [Topic].ipynb` (e.g. `Use Case - Chargeback.ipynb`)
- **Required sections** — Overview, Imports, Configuration, Load Data, Charts/API Calls, Next Steps
- **Overview requirements** — what data it needs, what questions it answers, when to use it vs. a sibling notebook
- **Code cell metadata** — `source_hidden: true` + `hide-input` tag on all chart/processing cells except Configuration
- **Configuration pattern** — ipywidgets form, auto-apply on Run All, secrets via `.env` only
- **Per-section structure** — API notebooks use `Purpose / Path Parameters / Query Parameters / Sample Response / Response Fields`; chart notebooks use a title + italic question per subsection
- **Execution summary pattern** — each API call prints `── label ──`, Request, Params, Response, Saved, Sample record

---

## Reference

- [Official documentation](https://developer.ibm.com/apis/catalog/sovcore--ibm-sovereign-core-apis/api/API--sovcore--ibm-sovereign-core-apis#getRawUsageByServiceProxy) 

---

**Published On:** 28 August 2026
