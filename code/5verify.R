# =============================================================================
# Step 5: Verify all scheduling constraints
# =============================================================================

library(testthat)

source(here::here("code", "config.R"))

schedule <- read_csv(here("data", "schedule.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id), session_id = as.character(session_id))

# IDs that should never appear
excluded_all <- as.character(c(reject_ids, withdraw_ids, dissertation_ids, panel_discussion_ids))

# IDs that should appear
expected_ids <- as.character(
  submissions %>% filter(!id %in% excluded_all) %>% pull(id)
)

cat(sprintf(
  "Schedule: %d rows | %d unique submissions | %d sessions\n\n",
  nrow(schedule), n_distinct(schedule$id), n_distinct(schedule$session_id)
))

# ── 1. Excluded IDs ──

test_that("No rejected IDs in schedule", {
  expect_equal(sort(intersect(schedule$id, as.character(reject_ids))), character(0))
})

test_that("No withdrawn IDs in schedule", {
  expect_equal(sort(intersect(schedule$id, as.character(withdraw_ids))), character(0))
})

test_that("No dissertation IDs in schedule", {
  expect_equal(sort(intersect(schedule$id, as.character(dissertation_ids))), character(0))
})

test_that("No panel discussion IDs in schedule", {
  expect_equal(sort(intersect(schedule$id, as.character(panel_discussion_ids))), character(0))
})

# ── 2. Expected IDs ──

test_that("All accepted submissions are scheduled", {
  expect_equal(sort(setdiff(expected_ids, schedule$id)), character(0))
})

test_that("No unexpected IDs in schedule", {
  expect_equal(sort(setdiff(schedule$id, expected_ids)), character(0))
})

# ── 3. No duplicates ──

test_that("Each submission ID appears exactly once", {
  dup_ids <- schedule %>%
    filter(!id %in% as.character(self_organized_panel_ids)) %>%
    count(id) %>% filter(n > 1) %>% pull(id)
  expect_equal(sort(dup_ids), character(0))
})

# ── 4. Session consistency ──

test_that("All rows within a session share the same slot, room, and name", {
  inconsistent <- schedule %>%
    group_by(session_id) %>%
    summarise(n_slots = n_distinct(time_slot), n_rooms = n_distinct(room),
              n_names = n_distinct(session_name), .groups = "drop") %>%
    filter(n_slots > 1 | n_rooms > 1 | n_names > 1) %>%
    pull(session_id)
  expect_equal(sort(inconsistent), character(0))
})

# ── 5. No room conflicts ──

test_that("No two sessions share the same room and time slot", {
  conflicts <- schedule %>%
    distinct(session_id, time_slot, room) %>%
    count(time_slot, room) %>% filter(n > 1)
  expect_equal(nrow(conflicts), 0L)
})

# ── 6. Date restrictions ──

test_that("All date-restricted submissions are on their required date", {
  restriction_ids <- as.integer(names(date_restrictions))
  violations <- map_dfr(restriction_ids, function(sid) {
    required <- as.Date(date_restrictions[[as.character(sid)]])
    row <- schedule %>% filter(id == as.character(sid)) %>% distinct(id, date)
    if (nrow(row) == 0) return(tibble(id = sid, issue = "not scheduled"))
    if (row$date != required) return(tibble(id = sid, issue = sprintf("on %s, required %s", row$date, required)))
    tibble()
  })
  expect_equal(nrow(violations), 0L,
    label = if (nrow(violations) > 0) paste(paste0("id ", violations$id, ": ", violations$issue), collapse = "; "))
})

# ── 7. Date exclusions ──

test_that("No date-excluded submissions are on their excluded date", {
  exclusion_ids <- as.integer(names(date_exclusions))
  violations <- map_dfr(exclusion_ids, function(sid) {
    excluded <- as.Date(date_exclusions[[as.character(sid)]])
    row <- schedule %>% filter(id == as.character(sid)) %>% select(id, date)
    if (nrow(row) == 0 || row$date != excluded) return(tibble())
    tibble(id = sid, issue = sprintf("on excluded date %s", row$date))
  })
  expect_equal(nrow(violations), 0L,
    label = if (nrow(violations) > 0) paste(paste0("id ", violations$id, ": ", violations$issue), collapse = "; "))
})

# ── 8. Session sizes ──

session_sizes <- schedule %>% count(session_id, name = "n_papers")

test_that("No session has fewer than 3 papers", {
  expect_equal(sort(session_sizes %>% filter(n_papers < 3) %>% pull(session_id)), character(0))
})

test_that("No session has more than 5 papers", {
  expect_equal(sort(session_sizes %>% filter(n_papers > 5) %>% pull(session_id)), character(0))
})

# ── 9. PDW registrants ──

test_that("No PDW-registered author is scheduled in W1 or W2", {
  pdw_registered <- read_csv(here("data", "pdw-registered.csv"), show_col_types = FALSE) %>%
    mutate(author_name = str_to_lower(`Full Name`)) %>% pull(author_name)

  violations <- schedule %>%
    filter(time_slot %in% c("W1", "W2")) %>%
    left_join(submissions %>% mutate(id = as.character(id)) %>% select(id, authors),
      by = "id", relationship = "many-to-many") %>%
    filter(!is.na(authors)) %>%
    mutate(author_list = str_split(authors, ";")) %>%
    unnest(author_list) %>%
    mutate(author_name = str_to_lower(str_trim(str_replace(author_list, "\\s*\\(.*", "")))) %>%
    filter(author_name %in% pdw_registered) %>%
    distinct(id, session_id, time_slot, author_name)

  expect_equal(nrow(violations), 0L)
})

# ── 10. Slot restrictions ──

test_that("All slot-restricted submissions are in their required slot", {
  if (!exists("slot_restrictions") || length(slot_restrictions) == 0) skip("No slot restrictions")

  session_ids_csv <- read_csv(here("data", "session-ids.csv"), show_col_types = FALSE) %>%
    mutate(id = as.character(id), session_id = as.character(session_id))

  violations <- map_dfr(names(slot_restrictions), function(pid) {
    required_slot <- slot_restrictions[[pid]]
    sess <- session_ids_csv %>% filter(id == pid) %>% pull(session_id) %>% unique()
    if (length(sess) == 0) return(tibble(id = pid, issue = "not in session-ids"))
    row <- schedule %>% filter(session_id %in% sess) %>% distinct(session_id, time_slot)
    if (nrow(row) == 0) return(tibble(id = pid, issue = "not scheduled"))
    if (row$time_slot[1] != required_slot) return(tibble(id = pid, issue = sprintf("in %s, required %s", row$time_slot[1], required_slot)))
    tibble()
  })
  expect_equal(nrow(violations), 0L)
})

# ── 11. No author double-booking ──

test_that("No author appears in multiple sessions at the same time", {
  conflicts <- schedule %>%
    left_join(submissions %>% mutate(id = as.character(id)) %>% select(id, authors),
      by = "id", relationship = "many-to-many") %>%
    filter(!is.na(authors)) %>%
    select(id, session_id, time_slot, authors) %>%
    mutate(author_list = str_split(authors, ";")) %>%
    unnest(author_list) %>%
    mutate(author_name = str_to_lower(str_trim(str_replace(author_list, "\\s*\\(.*", "")))) %>%
    filter(author_name != "") %>%
    distinct(session_id, time_slot, author_name) %>%
    group_by(author_name, time_slot) %>%
    filter(n_distinct(session_id) > 1) %>%
    summarise(sessions = paste(sort(unique(session_id)), collapse = ", "), .groups = "drop")

  # Filter out known non-attending conflicts
  if (exists("ignore_conflict_authors") && length(ignore_conflict_authors) > 0) {
    pattern <- paste(ignore_conflict_authors, collapse = "|")
    conflicts <- conflicts %>% filter(!str_detect(author_name, pattern))
  }

  print(conflicts)
  expect_equal(nrow(conflicts), 0L)
})

# ── 12. Paper order integrity ──

test_that("Every paper has an explicit paper_order", {
  missing <- schedule %>% filter(is.na(paper_order))
  expect_equal(nrow(missing), 0L)
})

test_that("Paper orders are unique within each session", {
  dups <- schedule %>%
    group_by(session_id) %>%
    filter(duplicated(paper_order)) %>%
    ungroup()
  expect_equal(nrow(dups), 0L)
})

# ── Distribution check ──

cat("\n\n=== Session distribution by category and time slot ===\n")
schedule %>%
  left_join(submissions %>% mutate(id = as.character(id)) %>% select(id, category) %>% distinct(), by = "id") %>%
  distinct(session_id, time_slot, category) %>%
  count(time_slot, category, name = "n") %>%
  tidyr::pivot_wider(names_from = time_slot, values_from = n, values_fill = 0L) %>%
  arrange(category) %>%
  print(n = 100)

cat("\nSessions per time slot:\n")
schedule %>%
  distinct(session_id, time_slot) %>%
  count(time_slot, name = "n_sessions") %>%
  print()
