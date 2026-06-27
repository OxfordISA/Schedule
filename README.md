# ISA Conference Schedule Template

This repository contains everything needed to build the ISA annual conference schedule: a data pipeline that assigns papers to time slots, a Quarto document that generates the printed program PDF, and a web app for attendees to browse the schedule online.

It is designed to be reused each year. You update the data files and configuration for your conference, re-run the pipeline, and publish.

## Quick Start

### Prerequisites

- **R** (4.0+) with packages: `tidyverse`, `here`, `jsonlite`
- **Quarto** (for rendering the PDF program)
- A **GitHub** account (for hosting the web app via GitHub Pages)

### One-Time Setup

1. Fork or clone this repository.
2. Edit `code/config.R` with your conference details (name, dates, venue, tracks, etc.).
3. Place your raw submissions export in `data/submissions_raw.csv`.

### Pipeline

Run these scripts in order from the repo root:

```bash
Rscript code/0clean.R                 # Clean raw submissions → data/submissions.csv
Rscript code/0b_export_for_chairs.R   # Generate draft CSVs for track chairs
# --- pause: track chairs organize papers into sessions ---
Rscript code/1generate_session_ids.R  # Build session-ids.csv from data/sessions/ CSVs
Rscript code/2assign_slots.R          # Assign sessions to time slots → data/schedule.csv
Rscript code/3exclude.R               # Remove excluded IDs
Rscript code/4generate_json.R         # Build JSON files for the web app
quarto render schedule.qmd            # Render the printed program PDF
Rscript code/5verify.R                # Verify all constraints are satisfied
```

## Repository Structure

```
code/
  config.R                  # ALL conference-specific settings (edit this first)
  setup.R                   # Loads libraries
  0clean.R                  # Raw submissions → cleaned submissions.csv
  0b_export_for_chairs.R    # Generates draft CSVs for track chairs to organize
  1generate_session_ids.R   # Combines session CSVs → session-ids.csv
  2assign_slots.R           # Assigns sessions to time slots and rooms
  3exclude.R                # Removes rejected/withdrawn papers from outputs
  4generate_json.R          # Generates JSON files for the web app
  5verify.R                 # Validates all scheduling constraints
  generate_badges.R         # Generates name badges PDF

data/
  submissions_raw.csv       # INPUT: raw export from your submission system
  submissions.csv           # Cleaned submissions (output of 0clean.R)
  sessions/                 # Per-track CSVs with session assignments (from chairs)
  session-ids.csv           # Paper → session mapping (generated)
  session-slots.csv         # Available time slots and rooms (edit for your venue)
  schedule.csv              # Full schedule with slots and rooms (generated)
  panels.csv                # Special sessions and plenaries
  overview.csv              # Full program overview (breaks, meals, receptions, etc.)
  self-sessions.csv         # Papers in self-organized panels
  pdw-registered.csv        # PDW registrants (cannot present in PDW-overlapping slots)
  excursion-program.csv     # Excursion/tour program details
  registrants.csv           # Conference registrants (for badges)
  guests.csv                # Special guests/speakers (for badges)

css/style.css               # Web app styles
js/app.js                   # Web app logic
json/                       # Generated JSON files served by the web app
index.html                  # Web app shell (served by GitHub Pages)
schedule.qmd                # Quarto source for the printed program PDF
images/                     # Logo, QR code, venue map, photos
```

## Detailed Workflow

### Step 0: Configuration (`code/config.R`)

This is the single file where all conference-specific settings live. Update:

- **Conference identity**: name, dates, venue, city, timezone
- **Conference dates**: the actual calendar dates for each day
- **Tracks**: track names and their display colors
- **Submission IDs to exclude**: rejected, withdrawn, dissertation-only, panel discussions
- **Scheduling constraints**: date restrictions (paper must be on a specific day), date exclusions (paper must NOT be on a specific day), slot restrictions
- **PDW slots**: which time slots overlap with the Professional Development Workshop
- **Award mappings**: paper IDs that won awards
- **Random seed**: change to get a different random slot assignment

### Step 0a: Clean Submissions (`code/0clean.R`)

Takes `data/submissions_raw.csv` (the raw export from your submission system) and produces `data/submissions.csv`. Handles title-casing author names, fixing acronyms, recoding award categories, classifying submission types, and filtering out rejected/withdrawn papers.

### Step 0b: Export for Track Chairs (`code/0b_export_for_chairs.R`)

Generates draft CSVs in `data/sessions/draft/`, one per track. Each CSV has columns: `id`, `session_id`, `session_name`, `paper_order`, `title`, `authors`, `abstract`. The `session_id`, `session_name`, and `paper_order` columns are blank — track chairs fill these in to organize papers into sessions (typically 3–4 papers per session).

Once chairs return their organized CSVs, save the finalized versions (with only `id`, `session_id`, `session_name`, `paper_order` columns) into `data/sessions/`.

### Step 1: Generate Session IDs (`code/1generate_session_ids.R`)

Reads all CSVs in `data/sessions/` and combines them into `data/session-ids.csv`, which maps every paper to its session. The `paper_order` column flows through to control presentation order.

### Step 2: Assign Slots (`code/2assign_slots.R`)

The main scheduling algorithm. Assigns each session to a time slot and room from `data/session-slots.csv`. Respects all constraints:

- No author appears in two sessions at the same time
- Date restrictions and exclusions from `config.R`
- PDW registrants excluded from PDW-overlapping slots
- Optimizes for spreading tracks across different time slots

Output: `data/schedule.csv`.

To get a different assignment, change `SCHEDULE_SEED` in `config.R` and re-run.

### Step 3: Exclude (`code/3exclude.R`)

Removes any excluded paper IDs from `session-ids.csv` and `schedule.csv`.

### Step 4: Generate JSON (`code/4generate_json.R`)

Builds the JSON files that power the web app:

- `json/schedule_data.json` — all sessions, papers, and events
- `json/excursions_data.json` — excursion details
- `json/bios_data.json` — speaker bios
- `json/awards_data.json` — award information
- `json/committee_data.json` — committee/leadership data

### Step 5: Verify (`code/5verify.R`)

Checks all scheduling constraints are satisfied: session sizes (3–4 papers), no author conflicts, date restrictions honored, PDW conflicts, paper order completeness, etc. Run this after any changes.

### Rendering the PDF

```bash
quarto render schedule.qmd
```

Produces `schedule.pdf` — the printed conference program with title page, awards, session descriptions, and the full paper schedule with track colors.

### Generating Name Badges

```bash
Rscript code/generate_badges.R
```

Reads `data/registrants.csv` and `data/guests.csv` to produce `badges.pdf` (6 per page, duplex-ready with QR codes on the back).

## Data Files You Need to Provide

For a new conference, you need to supply or update:

| File | Description |
|---|---|
| `data/submissions_raw.csv` | Raw export from your submission system |
| `data/session-slots.csv` | Available time slots and rooms at your venue |
| `data/panels.csv` | Special sessions, plenaries |
| `data/overview.csv` | Full program overview (breaks, meals, receptions, excursions) |
| `data/self-sessions.csv` | Self-organized panel papers (if any) |
| `data/pdw-registered.csv` | PDW registrants |
| `data/registrants.csv` | All registrants (for badges) |
| `data/guests.csv` | Special guests/speakers (for badges) |
| `images/logo.png` | Conference logo |
| `images/qr-schedule.png` | QR code linking to the web schedule |
| `images/map.png` | Venue map |

Everything else is generated by the pipeline.

## Setting Up GitHub Pages

The web app (`index.html` + `css/` + `js/` + `json/`) is designed to be served via GitHub Pages.

1. Push this repository to GitHub.
2. Go to your repo's **Settings** → **Pages**.
3. Under **Source**, select **Deploy from a branch**.
4. Set the branch to `main` (or whichever branch you use) and the folder to `/ (root)`.
5. Click **Save**.
6. GitHub will publish the site at `https://<your-org>.github.io/<repo-name>/`.
7. After running the pipeline and pushing updated JSON files, the web app updates automatically.

If you use a custom domain, configure it in the Pages settings and add a `CNAME` file to the repo root.

## Common Tasks

**Reassign time slots**: Change `SCHEDULE_SEED` in `config.R`, re-run `2assign_slots.R`.

**Move a single paper between sessions** (without re-running the full assignment): Edit these three files manually:
1. `data/sessions/<track>.csv` — update `session_id`, `session_name`, `paper_order`
2. `data/session-ids.csv` — update `session_id`, `session_name`
3. `data/schedule.csv` — update `session_id`, `session_name`, `time_slot`, `room`, `date`, `day`, `start_time`, `end_time`, `time_order`

Then run steps 3, 4, and 5 to regenerate outputs and verify.

**Add a date restriction**: Add an entry to `date_restrictions` in `config.R`, re-run `2assign_slots.R`.

**Update special sessions or plenaries**: Edit `data/panels.csv`, re-run `4generate_json.R`, re-render `schedule.qmd`.

**Update breaks, meals, or social events**: Edit `data/overview.csv`, re-run `4generate_json.R`, re-render `schedule.qmd`.
