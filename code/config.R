# =============================================================================
# Conference Configuration
# =============================================================================
# Edit this file for each new conference. All conference-specific settings
# live here so the pipeline scripts don't need to change.
# =============================================================================

source(here::here("code", "setup.R"))

# Read submissions (produced by 0clean.R)
submissions <- read_csv(
  here("data", "submissions.csv"),
  show_col_types = FALSE
)

# --- Conference identity ---

CONF_NAME       <- "2026 Industry Studies Association Annual Conference"
CONF_SHORT_NAME <- "ISA 2026"
CONF_DATES      <- "June 3-5, 2026"
CONF_VENUE      <- "George Washington University"
CONF_CITY       <- "Washington, DC"
CONF_TIMEZONE   <- "America/New_York"  # IANA timezone for calendar exports

# --- Conference dates (used by date_restrictions / date_exclusions) ---

CONF_DAY_1 <- as.Date("2026-06-03")  # Wednesday
CONF_DAY_2 <- as.Date("2026-06-04")  # Thursday
CONF_DAY_3 <- as.Date("2026-06-05")  # Friday

# --- Random seed for reproducible slot assignment ---

SCHEDULE_SEED <- 1

# --- Submission status IDs ---

# Papers to reject (excluded from all outputs)
reject_ids <- c(104, 139)

# Panel discussion sessions (handled separately via panels.csv)
panel_discussion_ids <- c(70, 101, 115, 117, 136, 174, 182)

# Self-organized panel IDs
self_organized_panel_ids <- c(32, 131)

# Dissertations (accepted but not scheduled for presentation)
dissertation_ids <- c(53, 20, 79, 127, 202, 212, 207, 213)

# Withdrawn submissions (excluded from all outputs)
withdraw_ids <- c(
  153, 81, 115, 173, 165, 152, 158, 105, 106, 40, 155, 29, 112,
  22, 26, 102, 91, 31, 35, 57, 107, 23, 149, 80, 111, 13, 14,
  15, 16, 18, 19, 34, 38, 42, 43, 47, 58, 60, 68, 69, 78, 82,
  87, 88, 121, 129, 130, 145, 160, 164, 166, 167, 187, 188, 189,
  198, 97, 98, 99, 159, 161, 41
)

# Combined exclusion list used by 3exclude.R and 5verify.R
excluded_ids <- as.character(c(reject_ids, withdraw_ids, dissertation_ids))

# --- Track / category definitions ---
# Each track has: full name, short code (for PDF), LaTeX color name, hex color

tracks <- tribble(
  ~category,                                                      ~short, ~color_name,      ~color_hex,
  "General Industry Studies",                                      "GIS",  "gis",            "#E69F00",
  "Health Care Systems, Biotechnology, and Pharmaceuticals",       "Health", "health",        "#56B4E9",
  "Innovation, Entrepreneurship, and AI-Driven Transformation",    "Innovation", "innovation", "#CC79A7",
  "Labor Markets, Organizations, and the Future of Work",          "Labor", "labor",          "#B8860B",
  "Operations, Supply Chain, and AI-Enhanced Industry 4.0",        "Operations", "operations", "#0072B2",
  "Public Policy and Global Competitiveness",                      "Policy", "policy",        "#D55E00",
  "Sustainable Innovation, Energy, and Mobility",                  "Sustainability", "sustainability", "#009E73"
)

# Event color (social events, breaks, meals)
EVENT_COLOR_HEX <- "#17A2B8"

# --- Scheduling constraints ---

# Date restrictions: id -> required date (session MUST be on this date)
date_restrictions <- list(
  `200` = "2026-06-05",
  `199` = "2026-06-05",
  `131` = "2026-06-03",
  `71`  = "2026-06-04",
  `128` = "2026-06-04",
  `141` = "2026-06-05",
  `203` = "2026-06-04",
  `21`  = "2026-06-04"
)

# Date exclusions: id -> excluded date (session must NOT be on this date)
date_exclusions <- list(
  `133` = "2026-06-03",
  `148` = "2026-06-03",
  `50`  = "2026-06-03",
  `36`  = "2026-06-03",
  `51`  = "2026-06-03",
  `120` = "2026-06-05",
  `191` = "2026-06-05"
)

# Slot restrictions: id -> required time slot (most specific constraint)
slot_restrictions <- list(
  `170` = "T2",
  `147` = "W3",
  `100` = "W3"
)

# PDW overlap slots (registrants in pdw-registered.csv cannot present here)
pdw_slots <- c("W1", "W2")

# --- Known author conflicts to ignore in verification ---
# Authors who have conflicts but are known not to be attending
ignore_conflict_authors <- c("narayanan", "combemale")

# --- Recategorization (applied during cleaning step 0) ---
# Format: list of id -> new category
recategorize_ids <- list(
  `90`  = "Public Policy and Global Competitiveness",
  `115` = "Sustainable Innovation, Energy, and Mobility",
  `137` = "Health Care Systems, Biotechnology, and Pharmaceuticals"
)

# --- Award name mappings (raw submission value -> short code) ---
award_map <- c(
  "Best Paper in Innovation and Entrepreneurship Award" = "innovation",
  "Giarratani Rising Star Award"                        = "giarratani",
  "Babbage International Policy Forum Industrial Innovation Policy Award" = "babbage",
  "Dissertation Award"                                  = "dissertation"
)
