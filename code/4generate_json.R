# =============================================================================
# Step 4: Generate JSON files for the web app
# =============================================================================
# Input:  data/schedule.csv, data/submissions.csv, data/panels.csv,
#         data/overview.csv, data/self-sessions.csv, data/bios.csv,
#         data/awards.csv, data/excursion-program.csv, data/committee.csv
# Output: json/schedule_data.json, json/excursions_data.json,
#         json/bios_data.json, json/awards_data.json, json/committee_data.json
# =============================================================================

library(readr)
library(dplyr)
library(jsonlite)
library(lubridate)
library(stringr)

schedule    <- read_csv('data/schedule.csv', show_col_types = FALSE)
submissions <- read_csv('data/submissions.csv', show_col_types = FALSE)

# =============================================================================
# Paper sessions — use paper_order from schedule.csv (carried from session CSVs)
# =============================================================================

# Self-organized panel ordering
self_sessions_raw <- read_csv('data/self-sessions.csv', show_col_types = FALSE)

self_sessions_order <- self_sessions_raw %>%
  group_by(id) %>%
  mutate(self_paper_order = paper_order) %>%
  ungroup() %>%
  mutate(id = as.character(id)) %>%
  select(id, title, self_paper_order)

self_discussants <- self_sessions_raw %>%
  group_by(id) %>%
  summarize(
    discussant = first(discussant[!is.na(discussant) & str_trim(discussant) != ""]),
    .groups = "drop"
  ) %>%
  mutate(id = as.character(id))

paper_sessions <- schedule %>%
  distinct(id, .keep_all = TRUE) %>%
  left_join(
    submissions %>% select(id, title, abstract, authors, author_names, category, type),
    by = 'id'
  ) %>%
  mutate(
    id = as.character(id),
    session_id = as.character(session_id),
    start_time = as.character(start_time),
    end_time = as.character(end_time)
  ) %>%
  # Self-organized panel paper_order (overrides if present)
  left_join(self_sessions_order, by = c('id', 'title')) %>%
  mutate(paper_order = coalesce(as.integer(paper_order), self_paper_order)) %>%
  select(-self_paper_order) %>%
  left_join(self_discussants, by = 'id') %>%
  arrange(time_order, session_id, paper_order)

# --- Presenter helpers ---

get_presenter <- function(authors_str, author_names_str) {
  fallback <- coalesce(
    str_trim(str_extract(authors_str, "^.+?\\)")),
    str_trim(str_extract(authors_str, "^[^;,]+"))
  )
  if (is.na(author_names_str) || is.na(authors_str)) return(fallback)
  names_parts   <- str_split(author_names_str, ";\\s*")[[1]]
  authors_parts <- str_split(authors_str,      ";\\s*")[[1]]
  idx <- which(str_detect(names_parts, "\\*"))[1]
  if (is.na(idx) || idx > length(authors_parts)) return(fallback)
  str_trim(authors_parts[idx])
}

mark_presenter <- function(authors_str, author_names_str) {
  if (is.na(author_names_str) || is.na(authors_str)) return(authors_str)
  names_parts   <- str_split(author_names_str, ";\\s*")[[1]]
  authors_parts <- str_split(authors_str,      ";\\s*")[[1]]
  idx <- which(str_detect(names_parts, "\\*"))[1]
  if (is.na(idx) || idx > length(authors_parts)) return(authors_str)
  entry <- str_trim(authors_parts[idx])
  entry <- if (str_detect(entry, "\\(")) {
    str_replace(entry, "\\s*\\(", "* (")
  } else {
    paste0(entry, "*")
  }
  authors_parts[idx] <- entry
  paste(str_trim(authors_parts), collapse = "; ")
}

# Session chair: presenting author of first paper in session
session_chairs <- paper_sessions %>%
  filter(paper_order == 1) %>%
  mutate(session_chair = mapply(get_presenter, authors, author_names, USE.NAMES = FALSE)) %>%
  select(session_id, session_chair)

paper_sessions <- paper_sessions %>%
  left_join(session_chairs, by = 'session_id') %>%
  mutate(authors = mapply(mark_presenter, authors, author_names, USE.NAMES = FALSE))

# =============================================================================
# Panel sessions
# =============================================================================

panels <- read_csv('data/panels.csv', show_col_types = FALSE) %>%
  mutate(
    date_parsed = mdy(date),
    date = as.Date(date_parsed),
    day = case_when(
      date_parsed == as.Date("2026-06-03") ~ "Wednesday",
      date_parsed == as.Date("2026-06-04") ~ "Thursday",
      date_parsed == as.Date("2026-06-05") ~ "Friday",
      TRUE ~ format(date_parsed, "%A")
    ),
    room = str_trim(str_replace_all(room, "\\s+", " ")),
    start_time = as.character(time_start),
    end_time = as.character(time_end),
    start_secs = as.numeric(time_start),
    time_slot = case_when(
      day == "Wednesday"                                            ~ "WP1",
      day == "Thursday" & start_secs < 43200                       ~ "TP1",
      day == "Thursday" & start_secs >= 43200 & start_secs < 57600 ~ "TP2",
      day == "Thursday"                                            ~ "TP3",
      day == "Friday"                                              ~ "FP1"
    ),
    time_order = case_when(
      time_slot == "WP1" ~ 0.5,
      time_slot == "TP1" ~ 4.5,
      time_slot == "TP2" ~ 5.5,
      time_slot == "TP3" ~ 6.5,
      time_slot == "FP1" ~ 6.75
    ),
    type = if_else(id == "P1", "plenary", "special_session"),
    session_id = id, session_name = title,
    panelists = str_trim(panelists), moderator = str_trim(moderator),
    session_chair = NA_character_, discussant = NA_character_
  ) %>%
  select(id, session_id, session_name, type, category, date, day,
         start_time, end_time, time_slot, time_order, room,
         title, authors = panelists, abstract = description,
         moderator, panelists, session_chair, discussant)

# =============================================================================
# Overview events (breaks, meals, receptions)
# =============================================================================

covered_sessions <- c("Paper Sessions", "Opening Plenary", "Concurrent Panel Sessions")

events <- read_csv('data/overview.csv', show_col_types = FALSE, col_types = cols(.default = "c")) %>%
  rename_with(str_trim) %>%
  rename(weekday = Weekday, time_start_str = `Time Start`, time_end_str = `Time End`,
         session = Session, building = Building, room_raw = Room) %>%
  mutate(across(c(weekday, time_start_str, time_end_str, session), str_trim)) %>%
  filter(!session %in% covered_sessions) %>%
  mutate(
    date = case_when(
      weekday == "Wednesday" ~ as.Date("2026-06-03"),
      weekday == "Thursday"  ~ as.Date("2026-06-04"),
      weekday == "Friday"    ~ as.Date("2026-06-05")
    ),
    day = weekday,
    room = str_trim(paste(building, str_trim(str_replace_all(room_raw, "\\s+", " ")), sep = " — ")),
    start_secs = { t <- parse_date_time(time_start_str, orders = "I:M p", quiet = TRUE); hour(t) * 3600L + minute(t) * 60L },
    end_secs   = { t <- parse_date_time(time_end_str,   orders = "I:M p", quiet = TRUE); hour(t) * 3600L + minute(t) * 60L },
    start_time = sprintf("%02d:%02d:00", start_secs %/% 3600L, (start_secs %% 3600L) %/% 60L),
    end_time   = sprintf("%02d:%02d:00", end_secs   %/% 3600L, (end_secs   %% 3600L) %/% 60L),
    time_order = case_when(
      weekday == "Wednesday" & start_secs == 28800L ~ 0.10,
      weekday == "Wednesday" & start_secs == 34200L ~ 0.12,
      weekday == "Wednesday" & start_secs == 43200L ~ 0.30,
      weekday == "Wednesday" & start_secs == 50400L ~ 0.95,
      weekday == "Wednesday" & start_secs == 54600L ~ 1.50,
      weekday == "Wednesday" & start_secs == 64800L ~ 3.50,
      weekday == "Thursday"  & start_secs == 30000L ~ 3.80,
      weekday == "Thursday"  & start_secs == 36600L ~ 4.25,
      weekday == "Thursday"  & start_secs == 42000L ~ 4.75,
      weekday == "Thursday"  & start_secs == 54300L ~ 5.75,
      weekday == "Thursday"  & start_secs == 64800L ~ 6.55,
      weekday == "Friday"    & start_secs == 30000L ~ 6.65,
      weekday == "Friday"    & start_secs == 36000L ~ 6.80,
      weekday == "Friday"    & start_secs == 42000L ~ 7.50,
      TRUE ~ 99.0
    ),
    id = paste0("EV", row_number()), session_id = id, session_name = session,
    type = "event", time_slot = NA_character_, category = NA_character_,
    title = session, authors = NA_character_, abstract = NA_character_,
    moderator = NA_character_, panelists = NA_character_,
    session_chair = NA_character_, discussant = NA_character_
  ) %>%
  select(id, session_id, session_name, type, category, date, day,
         start_time, end_time, time_slot, time_order, room,
         title, authors, abstract, moderator, panelists, session_chair, discussant)

# =============================================================================
# Combine and write schedule JSON
# =============================================================================

all_data <- bind_rows(
  paper_sessions %>% select(-author_names),
  panels, events
) %>%
  arrange(time_order, session_id)

write_json(all_data, 'json/schedule_data.json', auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("Written %d paper + %d panel + %d event entries to schedule_data.json\n",
  nrow(paper_sessions), nrow(panels), nrow(events)))

# =============================================================================
# Auxiliary JSONs
# =============================================================================

# Bios
bios <- read_csv('data/bios.csv', show_col_types = FALSE)
write_json(bios, 'json/bios_data.json', auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("Written %d bio entries\n", nrow(bios)))

# Awards
awards <- read_csv('data/awards.csv', show_col_types = FALSE) %>%
  arrange(award_order, desc(rank == "Winner"))
write_json(awards, 'json/awards_data.json', auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("Written %d award entries\n", nrow(awards)))

# Excursions
excursions_meta <- read_csv('data/overview.csv', show_col_types = FALSE, col_types = cols(.default = "c")) %>%
  rename_with(str_trim) %>%
  filter(!is.na(excursion_id)) %>%
  rename(id = excursion_id, option = excursion_option, session_name = Session,
         day = Weekday, start_time = `Time Start`, end_time = `Time End`) %>%
  mutate(
    date = case_when(day == "Wednesday" ~ "2026-06-03", day == "Thursday" ~ "2026-06-04", day == "Friday" ~ "2026-06-05"),
    option = as.integer(option)
  ) %>%
  arrange(option)

excursion_program <- read_csv('data/excursion-program.csv', show_col_types = FALSE)

excursions_list <- lapply(seq_len(nrow(excursions_meta)), function(i) {
  ex   <- excursions_meta[i, ]
  prog <- excursion_program %>% filter(excursion_id == ex$id)
  entry <- list(
    id = ex$id[[1]], option = as.integer(ex$option[[1]]),
    session_name = ex$session_name[[1]], date = as.character(ex$date[[1]]),
    day = ex$day[[1]], start_time = ex$start_time[[1]], end_time = ex$end_time[[1]],
    meeting_point = ex$meeting_point[[1]],
    description = if (is.na(ex$description[[1]])) NULL else ex$description[[1]]
  )
  if (nrow(prog) > 0) {
    tl_rows <- prog %>% distinct(time_range, activity)
    entry$timeline <- lapply(seq_len(nrow(tl_rows)), function(t) {
      list(time = tl_rows$time_range[[t]], activity = tl_rows$activity[[t]])
    })
    spkr_rows <- prog %>% filter(!is.na(speaker_name) & speaker_name != "")
    if (nrow(spkr_rows) > 0) {
      entry$organizations <- lapply(unique(spkr_rows$activity), function(org_nm) {
        org_rows <- spkr_rows %>% filter(activity == org_nm)
        pt <- org_rows$org_panel_title[[1]]
        list(
          name = org_nm,
          panel_title = if (is.na(pt) || pt == "") NULL else pt,
          speakers = lapply(seq_len(nrow(org_rows)), function(k) {
            list(name = org_rows$speaker_name[[k]], role = org_rows$speaker_role[[k]])
          })
        )
      })
    }
  }
  entry
})

write_json(excursions_list, 'json/excursions_data.json', auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("Written %d excursion entries\n", length(excursions_list)))

# Committee
committee <- read_csv('data/committee.csv', show_col_types = FALSE) %>% arrange(sort_order)
to_records <- function(df) {
  lapply(seq_len(nrow(df)), function(i) list(name = df$name[i], role = df$role[i], affiliation = df$affiliation[i]))
}
committee_list <- list(
  board = to_records(committee %>% filter(group == "board")),
  iscc = to_records(committee %>% filter(group == "iscc")),
  stream_chairs = to_records(committee %>% filter(group == "stream_chairs"))
)
write_json(committee_list, 'json/committee_data.json', auto_unbox = TRUE, pretty = TRUE)
cat("Written committee data\n")
