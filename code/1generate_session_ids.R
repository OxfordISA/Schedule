# =============================================================================
# Step 1: Generate session-ids.csv from per-track session CSVs
# =============================================================================
# Input:  data/sessions/*.csv      (id, session_id, session_name, paper_order)
#         data/self-sessions.csv   (self-organized panel papers)
# Output: data/session-ids.csv     (paper -> session mapping with paper_order)
# =============================================================================

source(here::here("code", "setup.R"))

# --- Read paper sessions from data/sessions/ CSVs ---

sessions_dir <- here("data", "sessions")
csv_files <- list.files(sessions_dir, pattern = "\\.csv$", full.names = TRUE)

paper_sessions <- map(csv_files, \(f) read_csv(f, show_col_types = FALSE)) |>
  list_rbind() |>
  filter(!is.na(session_id), !is.na(session_name)) |>
  select(id, session_id, session_name, paper_order)

# --- Read self-organized panel sessions from data/self-sessions.csv ---

self_sessions_raw <- read_csv(
  here("data", "self-sessions.csv"),
  show_col_types = FALSE
)

max_paper_session_id <- max(paper_sessions$session_id, na.rm = TRUE)

panel_sessions <- self_sessions_raw |>
  distinct(id, session_name) |>
  arrange(id) |>
  mutate(session_id = max_paper_session_id + row_number()) |>
  left_join(
    self_sessions_raw |> select(id, paper_order),
    by = "id"
  ) |>
  select(id, session_id, session_name, paper_order)

# --- Combine and write ---

session_ids <- bind_rows(paper_sessions, panel_sessions) |>
  arrange(session_id, paper_order, id)

write_csv(session_ids, here("data", "session-ids.csv"))

cat(sprintf(
  "Written %d rows to session-ids.csv (%d sessions)\n",
  nrow(session_ids),
  n_distinct(session_ids$session_id)
))
