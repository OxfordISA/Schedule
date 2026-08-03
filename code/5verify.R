# =============================================================================
# Step 5: Verify scheduling and programme data constraints
# =============================================================================

library(testthat)
library(jsonlite)

source(here::here("code", "config.R"))

schedule <- read_csv(here("data", "schedule.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id), session_id = as.character(session_id)) %>%
  group_by(id) %>%
  mutate(id_occurrence = row_number()) %>%
  ungroup()

submissions_indexed <- submissions %>%
  mutate(id = as.character(id)) %>%
  group_by(id) %>%
  mutate(id_occurrence = row_number()) %>%
  ungroup()

expected_rows <- submissions_indexed %>% distinct(id, id_occurrence)
scheduled_rows <- schedule %>% distinct(id, id_occurrence)

schedule_details <- schedule %>%
  left_join(
    submissions_indexed %>%
      select(
        id, id_occurrence, type, category, authors, contact_author, moderator
      ),
    by = c("id", "id_occurrence")
  )

cat(sprintf(
  "Schedule: %d rows | %d submission rows | %d sessions\n\n",
  nrow(schedule), nrow(expected_rows), n_distinct(schedule$session_id)
))

# 1. Expected submission rows

test_that("All submission rows are scheduled", {
  missing <- anti_join(expected_rows, scheduled_rows, by = c("id", "id_occurrence"))
  expect_equal(nrow(missing), 0L)
})

test_that("No unexpected submission rows are scheduled", {
  unexpected <- anti_join(scheduled_rows, expected_rows, by = c("id", "id_occurrence"))
  expect_equal(nrow(unexpected), 0L)
})

# 2. No duplicate schedule rows

test_that("No schedule row is duplicated", {
  duplicate_rows <- schedule %>%
    count(id, id_occurrence, session_id, paper_order, time_slot, room, name = "n") %>%
    filter(n > 1)
  expect_equal(nrow(duplicate_rows), 0L)
})

# 3. Session consistency

test_that("All rows within a session share the same slot, room, and name", {
  inconsistent <- schedule %>%
    group_by(session_id) %>%
    summarise(
      n_slots = n_distinct(time_slot),
      n_rooms = n_distinct(room),
      n_names = n_distinct(session_name),
      .groups = "drop"
    ) %>%
    filter(n_slots > 1 | n_rooms > 1 | n_names > 1) %>%
    pull(session_id)
  expect_equal(sort(inconsistent), character(0))
})

# 4. No room conflicts

test_that("No two sessions share the same room and time slot", {
  conflicts <- schedule %>%
    distinct(session_id, time_slot, room) %>%
    count(time_slot, room) %>%
    filter(n > 1)
  expect_equal(nrow(conflicts), 0L)
})

# 5. Session sizes. Concurrent panels are intentionally single row sessions.

paper_session_sizes <- schedule_details %>%
  group_by(session_id) %>%
  summarise(
    n_rows = n(),
    all_papers = all(type == "paper"),
    .groups = "drop"
  ) %>%
  filter(all_papers)

test_that("No paper session has fewer than 2 papers", {
  expect_equal(
    sort(paper_session_sizes %>% filter(n_rows < 2) %>% pull(session_id)),
    character(0)
  )
})

test_that("No paper session has more than 5 papers", {
  expect_equal(
    sort(paper_session_sizes %>% filter(n_rows > 5) %>% pull(session_id)),
    character(0)
  )
})

# 6. Explicit chairs and panel moderators

session_chairs <- read_csv(
  here("data", "session-chairs.csv"),
  show_col_types = FALSE
) %>%
  mutate(session_id = as.character(session_id))

test_that("Every paper session has an explicit chair-source row", {
  paper_sessions <- schedule_details %>%
    filter(type == "paper") %>%
    distinct(session_id)
  missing <- anti_join(paper_sessions, session_chairs, by = "session_id")
  expect_equal(nrow(missing), 0L)
})

test_that("Every concurrent panel has a named moderator", {
  missing <- schedule_details %>%
    filter(type == "panel") %>%
    filter(is.na(moderator) | str_trim(moderator) == "")
  expect_equal(nrow(missing), 0L)
})

# 7. Slot restrictions

test_that("All slot-restricted submissions are in their required slot", {
  if (!exists("slot_restrictions") || length(slot_restrictions) == 0) {
    skip("No slot restrictions")
  }

  session_ids_csv <- read_csv(
    here("data", "session-ids.csv"),
    show_col_types = FALSE
  ) %>%
    mutate(id = as.character(id), session_id = as.character(session_id))

  violations <- map_dfr(names(slot_restrictions), function(pid) {
    required_slot <- slot_restrictions[[pid]]
    sess <- session_ids_csv %>%
      filter(id == pid) %>%
      pull(session_id) %>%
      unique()
    if (length(sess) == 0) return(tibble(id = pid, issue = "not in session-ids"))
    row <- schedule %>%
      filter(session_id %in% sess) %>%
      distinct(session_id, time_slot)
    if (nrow(row) == 0) return(tibble(id = pid, issue = "not scheduled"))
    if (row$time_slot[[1]] != required_slot) {
      return(tibble(
        id = pid,
        issue = sprintf("in %s, required %s", row$time_slot[[1]], required_slot)
      ))
    }
    tibble()
  })
  expect_equal(nrow(violations), 0L)
})

# 8. No author double booking

test_that("No author appears in multiple sessions at the same time", {
  conflicts <- schedule_details %>%
    filter(!is.na(authors)) %>%
    select(id, id_occurrence, session_id, time_slot, authors) %>%
    mutate(author_list = str_split(authors, ";")) %>%
    unnest(author_list) %>%
    mutate(
      author_name = str_to_lower(
        str_trim(str_replace(author_list, "\\s*\\(.*", ""))
      )
    ) %>%
    filter(author_name != "") %>%
    distinct(session_id, time_slot, author_name) %>%
    group_by(author_name, time_slot) %>%
    filter(n_distinct(session_id) > 1) %>%
    summarise(
      sessions = paste(sort(unique(session_id)), collapse = ", "),
      .groups = "drop"
    )

  if (exists("ignore_conflict_authors") && length(ignore_conflict_authors) > 0) {
    pattern <- paste(ignore_conflict_authors, collapse = "|")
    conflicts <- conflicts %>% filter(!str_detect(author_name, pattern))
  }

  print(conflicts)
  expect_equal(nrow(conflicts), 0L)
})

# 9. Paper order integrity

test_that("Every scheduled item has an explicit paper_order", {
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

# 10. Generated JSON integrity

json_schedule <- fromJSON(here("json", "schedule_data.json"), simplifyDataFrame = TRUE)

test_that("Every paper in JSON has exactly one presenter marker", {
  paper_json <- json_schedule %>% filter(type == "paper")
  marker_count <- str_count(coalesce(paper_json$authors, ""), fixed("*"))
  expect_true(all(marker_count == 1L))
})

test_that("Concurrent panels have moderators and panelists in JSON", {
  panel_json <- json_schedule %>% filter(type == "panel")
  expect_true(all(!is.na(panel_json$moderator) & str_trim(panel_json$moderator) != ""))
  expect_true(all(!is.na(panel_json$panelists) & str_trim(panel_json$panelists) != ""))
})

cat("\n\n=== Session distribution by category and time slot ===\n")
schedule_details %>%
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
