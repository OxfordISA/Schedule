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

CONF_NAME       <- "2026 Industry Studies Association International Conference"
CONF_SHORT_NAME <- "ISA Oxford 2026"
CONF_DATES      <- "September 3-5, 2026"
CONF_VENUE      <- "University of Oxford"
CONF_CITY       <- "Oxford UK"
CONF_TIMEZONE   <- "United Kingdom/London"  # IANA timezone for calendar exports

# --- Conference dates (used by date_restrictions / date_exclusions) ---

CONF_DAY_1 <- as.Date("2026-09-03")  # Thursday
CONF_DAY_2 <- as.Date("2026-09-04")  # Friday
CONF_DAY_3 <- as.Date("2026-09-05")  # Saturday

# --- Random seed for reproducible slot assignment ---

SCHEDULE_SEED <- 1

# --- Track / category definitions ---
# Each track has: full name, short code (for PDF), LaTeX color name, hex color

tracks <- tribble(
  ~category,                                                      ~short, ~color_name,      ~color_hex,
  "General Industry Studies",                                      "GIS",  "gis",            "#E69F00",
  "Health Care Systems, Biotechnology, and Pharmaceuticals",       "HC", "hc",        "#56B4E9",
  "Innovation, Entrepreneurship, and AI-Driven Transformation",    "I&E", "i&e", "#CC79A7",
  "Labor Markets, Organizations, and the Future of Work",          "Labor", "labor",          "#B8860B",
  "Operations, Supply Chain, and AI-Enhanced Industry 4.0",        "OSCM", "oscm", "#0072B2",
  "Public Policy and Global Competitiveness",                      "Policy", "policy",        "#D55E00",
  "Sustainable Innovation, Energy, and Mobility",                  "Sustainability", "sustainability", "#009E73"
  "Cross-track",                                                   "XTrack", "cross-track", "#009E79"
)

# Event color (social events, breaks, meals)
EVENT_COLOR_HEX <- "#17A2B8"


