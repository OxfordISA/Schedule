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

# 11. Auxiliary JSON structures used by JavaScript map operations

test_that("Auxiliary JSON files have the expected top-level structures", {
  bios_json <- fromJSON(here("json", "bios_data.json"), simplifyVector = FALSE)
  awards_json <- fromJSON(here("json", "awards_data.json"), simplifyVector = FALSE)
  excursions_json <- fromJSON(here("json", "excursions_data.json"), simplifyVector = FALSE)
  committee_json <- fromJSON(here("json", "committee_data.json"), simplifyVector = FALSE)

  expect_true(is.list(bios_json))
  expect_true(is.list(awards_json))
  expect_true(is.list(excursions_json))
  expect_true(is.list(committee_json))
  expect_true(is.list(committee_json$board))
  expect_true(is.list(committee_json$oxcc))
  expect_true(is.list(committee_json$stream_chairs))
})


# 12. Plenary and special-session speaker identity and image integrity

bios_csv <- read_csv(here("data", "bios.csv"), show_col_types = FALSE)
bio_panels_csv <- read_csv(here("data", "bio-panels.csv"), show_col_types = FALSE)
panels_csv <- read_csv(here("data", "panels.csv"), show_col_types = FALSE)

canonical_person_name <- function(x) {
  x <- coalesce(as.character(x), "")
  x <- str_remove(x, "\\s*\\(.*$")
  x <- iconv(x, to = "ASCII//TRANSLIT")
  x <- str_to_lower(str_squish(x))
  x <- str_replace(
    x,
    "^(the\\s+rt\\s+hon\\s+|professor\\s+sir\\s+|professor\\s+|prof\\.?\\s+|dr\\.?\\s+|sir\\s+)+",
    ""
  )
  x <- str_replace(x, "(?:\\s+(?:cbe|ceng|fice|freng|frs))+$", "")
  str_squish(x)
}

test_that("Every speaker mapping has exactly one biography record", {
  expect_true(all(!is.na(bios_csv$person_id) & str_trim(bios_csv$person_id) != ""))
  expect_equal(anyDuplicated(bios_csv$person_id), 0L)
  missing <- anti_join(
    bio_panels_csv %>% distinct(person_id),
    bios_csv %>% distinct(person_id),
    by = "person_id"
  )
  expect_equal(nrow(missing), 0L)
})

test_that("Every nonblank biography image points to a PNG file", {
  image_ids <- bios_csv %>%
    filter(!is.na(image), str_trim(image) != "") %>%
    pull(image)
  expect_equal(anyDuplicated(image_ids), 0L)
  missing_files <- image_ids[!file.exists(here("images", "bios", paste0(image_ids, ".png")))]
  expect_equal(sort(missing_files), character(0))
})

test_that("All plenary and special-session names resolve to biography records", {
  listed_people <- bind_rows(
    panels_csv %>%
      transmute(id, person = moderator) %>%
      filter(!is.na(person), str_trim(person) != ""),
    panels_csv %>%
      transmute(id, person = str_split(panelists, ";")) %>%
      unnest(person) %>%
      mutate(person = str_trim(person)) %>%
      filter(!is.na(person), person != "")
  ) %>%
    mutate(person_key = canonical_person_name(person))

  bio_keys <- bios_csv %>%
    transmute(person_id, name, person_key = canonical_person_name(name))

  unmatched <- anti_join(listed_people, bio_keys, by = "person_key")
  duplicate_keys <- bio_keys %>% count(person_key) %>% filter(person_key == "" | n > 1)
  expect_equal(nrow(unmatched), 0L)
  expect_equal(nrow(duplicate_keys), 0L)
})

test_that("Biography JSON preserves stable speaker IDs and optional image fields", {
  bios_json_df <- fromJSON(here("json", "bios_data.json"), simplifyDataFrame = TRUE)
  expect_true(all(c("person_id", "image", "name", "bio") %in% names(bios_json_df)))
  expect_equal(anyDuplicated(bios_json_df$person_id), 0L)
  expect_equal(sort(bios_json_df$person_id), sort(bios_csv$person_id))
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
