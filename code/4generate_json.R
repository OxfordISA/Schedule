# =============================================================================
# Step 4: Generate JSON files for the static conference programme
# =============================================================================
# Run from the repository root with:
#   Rscript code/4generate_json.R
# =============================================================================

source(here::here("code", "config.R"))

library(readr)
library(dplyr)
library(jsonlite)
library(lubridate)
library(stringr)
library(tidyr)

dir.create(here::here("json"), showWarnings = FALSE, recursive = TRUE)

clean_text <- function(x) {
  x <- as.character(x)
  x <- str_trim(x)
  x[x == ""] <- NA_character_
  x
}

normalise_room <- function(x) {
  str_to_lower(str_squish(coalesce(as.character(x), "")))
}

normalise_person <- function(x) {
  x <- iconv(coalesce(as.character(x), ""), to = "ASCII//TRANSLIT")
  x <- str_to_lower(x)
  x <- str_remove_all(x, "\\b(dr|prof|professor|mr|mrs|ms)\\.?\\b")
  x <- str_remove_all(x, "[0-9]+")
  x <- str_replace_all(x, "[^a-z]+", " ")
  str_squish(x)
}

parse_clock <- function(x) {
  parsed <- parse_date_time(
    as.character(x),
    orders = c("I:M p", "I p", "H:M:S", "H:M"),
    quiet = TRUE,
    tz = "UTC"
  )
  ifelse(is.na(parsed), NA_character_, format(parsed, "%H:%M:%S"))
}

clock_seconds <- function(x) {
  parsed <- parse_date_time(
    as.character(x),
    orders = c("H:M:S", "H:M", "I:M p", "I p"),
    quiet = TRUE,
    tz = "UTC"
  )
  ifelse(
    is.na(parsed),
    NA_real_,
    hour(parsed) * 3600 + minute(parsed) * 60 + second(parsed)
  )
}

combine_location <- function(building, room) {
  building <- clean_text(building)
  room <- clean_text(room)
  mapply(function(b, r) {
    if (is.na(b) && is.na(r)) return(NA_character_)
    if (is.na(b)) return(r)
    if (is.na(r)) return(b)
    if (str_to_lower(b) == str_to_lower(r)) return(b)
    paste(b, r, sep = " — ")
  }, building, room, USE.NAMES = FALSE)
}

mark_contact_author <- function(authors_str, contact_author) {
  if (is.na(authors_str) || str_trim(authors_str) == "") return(authors_str)
  if (is.na(contact_author) || str_trim(contact_author) == "") return(authors_str)

  parts <- str_split(authors_str, ";\\s*")[[1]]
  target <- normalise_person(contact_author)
  matches <- which(vapply(parts, function(part) {
    name_only <- str_trim(str_remove(part, "\\s*\\([^)]*\\)\\s*$"))
    normalise_person(name_only) == target
  }, logical(1)))

  if (length(matches) == 0) {
    matches <- which(vapply(parts, function(part) {
      candidate <- normalise_person(part)
      str_detect(candidate, fixed(target)) || str_detect(target, fixed(candidate))
    }, logical(1)))
  }

  if (length(matches) == 0) {
    stop(sprintf(
      "Could not match contact author '%s' in author list '%s'",
      contact_author,
      authors_str
    ))
  }

  idx <- matches[[1]]
  entry <- str_trim(parts[[idx]])
  if (!str_detect(entry, "\\*")) {
    entry <- if (str_detect(entry, "\\(")) {
      str_replace(entry, "\\s*\\(", "* (")
    } else {
      paste0(entry, "*")
    }
  }
  parts[[idx]] <- entry
  paste(str_trim(parts), collapse = "; ")
}

conference_day_map <- tibble(
  day = format(c(CONF_DAY_1, CONF_DAY_2, CONF_DAY_3), "%A"),
  date = as.Date(c(CONF_DAY_1, CONF_DAY_2, CONF_DAY_3))
)

schedule <- read_csv(here::here("data", "schedule.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id)) %>%
  group_by(id) %>%
  mutate(id_occurrence = row_number()) %>%
  ungroup()

submissions <- read_csv(here::here("data", "submissions.csv"), show_col_types = FALSE) %>%
  mutate(id = as.character(id)) %>%
  group_by(id) %>%
  mutate(id_occurrence = row_number()) %>%
  ungroup()

# =============================================================================
# Concurrent paper and panel sessions
# =============================================================================

self_sessions_path <- here::here("data", "self-sessions.csv")
if (file.exists(self_sessions_path)) {
  self_sessions_raw <- read_csv(self_sessions_path, show_col_types = FALSE)
} else {
  self_sessions_raw <- tibble(
    id = character(),
    title = character(),
    paper_order = integer(),
    discussant = character()
  )
}

self_sessions_order <- self_sessions_raw %>%
  transmute(
    id = as.character(id),
    title = as.character(title),
    self_paper_order = as.integer(paper_order)
  )

self_discussants <- self_sessions_raw %>%
  mutate(id = as.character(id), discussant = clean_text(discussant)) %>%
  group_by(id) %>%
  summarize(
    discussant = first(na.omit(discussant), default = NA_character_),
    .groups = "drop"
  )

session_chairs_path <- here::here("data", "session-chairs.csv")
if (!file.exists(session_chairs_path)) {
  stop("Missing data/session-chairs.csv. Session chairs must be explicit and are not inferred from paper authors.")
}

session_chairs <- read_csv(session_chairs_path, show_col_types = FALSE) %>%
  transmute(
    session_id = as.character(session_id),
    session_chair = clean_text(session_chair)
  ) %>%
  distinct(session_id, .keep_all = TRUE)

paper_sessions <- schedule %>%
  left_join(
    submissions %>%
      select(
        id, id_occurrence, title, abstract, authors, contact_author,
        author_names, category, type, moderator
      ),
    by = c("id", "id_occurrence")
  ) %>%
  mutate(
    session_id = as.character(session_id),
    date = as.Date(date),
    start_time = parse_clock(start_time),
    end_time = parse_clock(end_time),
    type = clean_text(type),
    category = clean_text(category),
    moderator = clean_text(moderator)
  ) %>%
  left_join(self_sessions_order, by = c("id", "title")) %>%
  mutate(paper_order = coalesce(as.integer(paper_order), self_paper_order)) %>%
  select(-self_paper_order) %>%
  left_join(self_discussants, by = "id") %>%
  left_join(session_chairs, by = "session_id") %>%
  mutate(
    authors = if_else(
      type == "paper",
      mapply(mark_contact_author, authors, contact_author, USE.NAMES = FALSE),
      authors
    ),
    panelists = if_else(type == "panel", authors, NA_character_),
    session_chair = if_else(type == "panel", NA_character_, session_chair)
  ) %>%
  arrange(date, start_time, session_id, paper_order)

if (any(is.na(paper_sessions$title))) {
  bad <- paper_sessions %>% filter(is.na(title)) %>% distinct(id, id_occurrence)
  stop(
    "Some schedule rows could not be paired with submissions.csv occurrences: ",
    paste(paste0(bad$id, "#", bad$id_occurrence), collapse = ", ")
  )
}

# =============================================================================
# Plenaries and true special sessions from panels.csv
# =============================================================================

session_slots <- read_csv(
  here::here("data", "session-slots.csv"),
  show_col_types = FALSE,
  col_types = cols(.default = "c")
) %>%
  transmute(
    slot_date = as.Date(date),
    slot_start = parse_clock(start_time),
    slot_end = parse_clock(end_time),
    room_key = normalise_room(room),
    time_slot
  ) %>%
  distinct()

panels <- read_csv(
  here::here("data", "panels.csv"),
  show_col_types = FALSE,
  col_types = cols(.default = "c")
) %>%
  mutate(
    date = as.Date(mdy(date)),
    day = format(date, "%A"),
    room = str_squish(room),
    room_key = normalise_room(room),
    start_time = parse_clock(time_start),
    end_time = parse_clock(time_end)
  ) %>%
  left_join(
    session_slots,
    by = c(
      "date" = "slot_date",
      "start_time" = "slot_start",
      "end_time" = "slot_end",
      "room_key"
    )
  ) %>%
  mutate(
    type = if_else(
      str_starts(id, "PL") | str_to_lower(category) == "plenary",
      "plenary",
      "special_session"
    ),
    session_id = id,
    session_name = title,
    category = if_else(type == "plenary", NA_character_, clean_text(category)),
    panelists = clean_text(panelists),
    moderator = clean_text(moderator),
    authors = panelists,
    abstract = clean_text(description),
    session_chair = NA_character_,
    discussant = NA_character_,
    paper_order = 1L
  ) %>%
  select(
    id, session_id, session_name, paper_order, type, category, date, day,
    start_time, end_time, time_slot, room, title, authors, abstract,
    moderator, panelists, session_chair, discussant
  )

# =============================================================================
# Overview rows
# =============================================================================

overview <- read_csv(
  here::here("data", "overview.csv"),
  show_col_types = FALSE,
  col_types = cols(.default = "c")
) %>%
  rename_with(str_trim) %>%
  rename(
    weekday = Weekday,
    time_start_str = `Time Start`,
    time_end_str = `Time End`,
    session = Session,
    building = Building,
    room_raw = Room
  ) %>%
  mutate(
    overview_row_id = row_number(),
    across(c(weekday, time_start_str, time_end_str, session, building, room_raw), clean_text)
  ) %>%
  left_join(conference_day_map, by = c("weekday" = "day"))

programme_heading_pattern <- regex(
  "^(regular |concurrent )?(paper( and panel)?|panel|special) sessions?\\b|^(opening )?plenary\\b",
  ignore_case = TRUE
)

social_names <- c(
  "breakfast",
  "coffee break",
  "lunch",
  "lunch and best paper award presentation",
  "gala dinner",
  "welcome reception"
)

events <- overview %>%
  filter(!str_detect(session, programme_heading_pattern)) %>%
  mutate(
    start_time = parse_clock(time_start_str),
    end_time = parse_clock(time_end_str),
    room = combine_location(building, room_raw),
    id = paste0("EV", overview_row_id),
    session_id = id,
    session_name = session,
    type = if_else(str_to_lower(session) %in% social_names, "event", "activity"),
    category = NA_character_,
    time_slot = NA_character_,
    title = session,
    authors = NA_character_,
    abstract = clean_text(description),
    moderator = NA_character_,
    panelists = NA_character_,
    session_chair = NA_character_,
    discussant = NA_character_,
    paper_order = 1L,
    day = weekday
  ) %>%
  select(
    id, session_id, session_name, paper_order, type, category, date, day,
    start_time, end_time, time_slot, room, title, authors, abstract,
    moderator, panelists, session_chair, discussant
  )

if (any(is.na(events$date))) {
  bad_days <- unique(events$day[is.na(events$date)])
  stop(
    "Overview contains weekdays outside the configured conference dates: ",
    paste(bad_days, collapse = ", ")
  )
}

# =============================================================================
# Combine and write schedule JSON
# =============================================================================

all_data <- bind_rows(
  paper_sessions %>%
    select(-author_names, -contact_author, -id_occurrence, -time_order),
  panels,
  events
) %>%
  mutate(
    date = as.Date(date),
    start_seconds = clock_seconds(start_time),
    time_order = as.numeric(date) * 100000 + coalesce(start_seconds, 0)
  ) %>%
  arrange(date, start_seconds, session_id, paper_order) %>%
  select(
    id, session_id, session_name, paper_order, type, category, date, day,
    start_time, end_time, time_slot, time_order, room, title, authors,
    abstract, moderator, panelists, session_chair, discussant
  )

write_json(
  all_data,
  here::here("json", "schedule_data.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null"
)
cat(sprintf(
  "Written %d concurrent records, %d plenary/special records, and %d overview records to schedule_data.json\n",
  nrow(paper_sessions), nrow(panels), nrow(events)
))

# =============================================================================
# Auxiliary JSON files
# =============================================================================

bios <- read_csv(here::here("data", "bios.csv"), show_col_types = FALSE)
write_json(
  bios,
  here::here("json", "bios_data.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null"
)
cat(sprintf("Written %d bio entries to bios_data.json\n", nrow(bios)))

awards <- read_csv(here::here("data", "awards.csv"), show_col_types = FALSE) %>%
  arrange(award_order, desc(rank == "Winner"))
write_json(
  awards,
  here::here("json", "awards_data.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null"
)
cat(sprintf("Written %d award entries to awards_data.json\n", nrow(awards)))

excursions_meta <- overview %>%
  filter(!is.na(excursion_id), str_trim(excursion_id) != "") %>%
  transmute(
    id = excursion_id,
    option = suppressWarnings(as.integer(excursion_option)),
    session_name = session,
    date = as.character(date),
    day = weekday,
    start_time = time_start_str,
    end_time = time_end_str,
    meeting_point = clean_text(meeting_point),
    description = clean_text(description)
  ) %>%
  arrange(option)

excursion_program <- read_csv(
  here::here("data", "excursion-program.csv"),
  show_col_types = FALSE
)

excursions_list <- lapply(seq_len(nrow(excursions_meta)), function(i) {
  ex <- excursions_meta[i, ]
  prog <- excursion_program %>%
    filter(as.character(excursion_id) == as.character(ex$id[[1]]))
  entry <- list(
    id = ex$id[[1]],
    option = ex$option[[1]],
    session_name = ex$session_name[[1]],
    date = ex$date[[1]],
    day = ex$day[[1]],
    start_time = ex$start_time[[1]],
    end_time = ex$end_time[[1]],
    meeting_point = ex$meeting_point[[1]],
    description = ex$description[[1]]
  )
  if (nrow(prog) > 0) {
    timeline_rows <- prog %>% distinct(time_range, activity)
    entry$timeline <- lapply(seq_len(nrow(timeline_rows)), function(t) {
      list(
        time = timeline_rows$time_range[[t]],
        activity = timeline_rows$activity[[t]]
      )
    })
    speaker_rows <- prog %>%
      filter(!is.na(speaker_name), str_trim(speaker_name) != "")
    if (nrow(speaker_rows) > 0) {
      entry$organizations <- lapply(unique(speaker_rows$activity), function(org_name) {
        org_rows <- speaker_rows %>% filter(activity == org_name)
        list(
          name = org_name,
          panel_title = clean_text(org_rows$org_panel_title[[1]]),
          speakers = lapply(seq_len(nrow(org_rows)), function(k) {
            list(
              name = org_rows$speaker_name[[k]],
              role = org_rows$speaker_role[[k]]
            )
          })
        )
      })
    }
  }
  entry
})

write_json(
  excursions_list,
  here::here("json", "excursions_data.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null"
)
cat(sprintf(
  "Written %d excursion entries to excursions_data.json\n",
  length(excursions_list)
))

committee <- read_csv(here::here("data", "committee.csv"), show_col_types = FALSE) %>%
  mutate(group = str_to_lower(str_trim(group))) %>%
  arrange(group, as.integer(sort_order))

to_records <- function(df) {
  lapply(seq_len(nrow(df)), function(i) {
    list(
      name = df$name[[i]],
      role = df$role[[i]],
      affiliation = df$affiliation[[i]]
    )
  })
}

committee_list <- list(
  board = to_records(committee %>% filter(group == "board")),
  oxcc = to_records(committee %>% filter(group %in% c("oxcc", "iscc"))),
  stream_chairs = to_records(committee %>% filter(group == "stream_chairs"))
)

write_json(
  committee_list,
  here::here("json", "committee_data.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  na = "null"
)
cat(sprintf(
  "Written committee data: %d board, %d Oxford committee, %d stream chair records\n",
  length(committee_list$board),
  length(committee_list$oxcc),
  length(committee_list$stream_chairs)
))
