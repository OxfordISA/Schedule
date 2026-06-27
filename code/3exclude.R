# =============================================================================
# Step 3: Remove excluded IDs from session-ids.csv and schedule.csv
# =============================================================================
# Input/Output: data/session-ids.csv, data/schedule.csv (modified in place)
# =============================================================================

library(readr)
library(dplyr)
library(here)

source(here("code", "config.R"))

# ── Remove from session-ids.csv ──

session_ids <- read_csv(here("data", "session-ids.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id))

removed <- session_ids %>% filter(id %in% excluded_ids)
session_ids_clean <- session_ids %>% filter(!id %in% excluded_ids)
write_csv(session_ids_clean, here("data", "session-ids.csv"))

cat(sprintf("session-ids.csv: removed %d row(s)\n", nrow(removed)))

# ── Remove from schedule.csv ──

schedule <- read_csv(here("data", "schedule.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id))

removed_sched <- schedule %>% filter(id %in% excluded_ids)
schedule_clean <- schedule %>% filter(!id %in% excluded_ids)
write_csv(schedule_clean, here("data", "schedule.csv"))

cat(sprintf("schedule.csv: removed %d row(s)\n", nrow(removed_sched)))

# ── Warn about undersized sessions ──

undersized <- schedule_clean %>%
  count(session_id, session_name, name = "n_papers") %>%
  filter(n_papers < 3)

if (nrow(undersized) > 0) {
  cat(sprintf("\nWARNING: %d session(s) now have fewer than 3 papers:\n", nrow(undersized)))
  for (i in seq_len(nrow(undersized))) {
    cat(sprintf("  session %s ('%s'): %d paper(s)\n",
      undersized$session_id[i], undersized$session_name[i], undersized$n_papers[i]))
  }
} else {
  cat("All sessions have 3+ papers.\n")
}
