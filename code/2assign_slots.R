# =============================================================================
# Step 2: Assign sessions to time slots and rooms
# =============================================================================
# Input:  data/session-ids.csv, data/session-slots.csv, data/submissions.csv
# Output: data/schedule.csv (with time_slot, room, day, date, start/end times)
# =============================================================================

source(here::here("code", "config.R"))

# --- Read session IDs ---
session_ids <- read_csv(here("data", "session-ids.csv"), show_col_types = FALSE)

# --- Read available slots ---
session_slots <- read_csv(here("data", "session-slots.csv"), show_col_types = FALSE)

# --- Get unique sessions with category info ---
session_categories <- session_ids %>%
  left_join(submissions %>% select(id, category) %>% distinct(), by = "id") %>%
  group_by(session_id) %>%
  slice(1) %>%
  ungroup() %>%
  select(session_id, session_name, category)

# --- Extract authors for conflict avoidance ---
all_authors_by_session <- session_ids %>%
  left_join(submissions %>% select(id, authors) %>% distinct(), by = "id") %>%
  filter(!is.na(authors)) %>%
  select(session_id, authors) %>%
  mutate(author_list = str_split(authors, ";")) %>%
  unnest(author_list) %>%
  mutate(author_name = str_to_lower(str_trim(str_replace(author_list, "\\s*\\(.*", "")))) %>%
  filter(author_name != "") %>%
  select(session_id, author_name) %>%
  distinct()

session_authors_map <- all_authors_by_session %>%
  group_by(session_id) %>%
  summarise(authors = list(author_name), .groups = "drop") %>%
  deframe()

cat("Total sessions to assign:", nrow(session_categories), "\n")

# --- Load PDW registrants ---
pdw_registered <- read_csv(
  here("data", "pdw-registered.csv"), show_col_types = FALSE
) %>%
  mutate(author_name = str_to_lower(`Full Name`)) %>%
  pull(author_name)

pdw_sessions <- all_authors_by_session %>%
  filter(author_name %in% pdw_registered) %>%
  pull(session_id) %>%
  unique()

cat("PDW-conflicted sessions:", paste(pdw_sessions, collapse = ", "), "\n")

# --- Define time slot order ---
available_time_slots <- session_slots %>% distinct(time_slot) %>% pull(time_slot)
time_slot_order_full <- c("W1", "W2", "W3", "T1", "T2", "T3", "T4", "F1")
time_slot_order <- time_slot_order_full[time_slot_order_full %in% available_time_slots]

cat("Using time slots:", paste(time_slot_order, collapse = ", "), "\n")

# Add time order to slots
session_slots <- session_slots %>%
  mutate(time_order = match(time_slot, time_slot_order)) %>%
  arrange(time_order, room)

slots_per_time <- session_slots %>% count(time_slot, name = "n_rooms")
slot_capacity <- setNames(slots_per_time$n_rooms, slots_per_time$time_slot)
slot_capacity <- slot_capacity[time_slot_order]
all_slots <- rep(time_slot_order, slot_capacity[time_slot_order])

cat("Total available slots:", length(all_slots), "\n")

if (nrow(session_categories) > length(all_slots)) {
  stop("More sessions (", nrow(session_categories), ") than available slots (", length(all_slots), ")")
}

# --- Build constraint maps ---
slot_to_date <- session_slots %>%
  distinct(time_slot, date) %>%
  { setNames(as.Date(.$date), .$time_slot) }

build_session_constraint_map <- function(config_list) {
  if (length(config_list) == 0) return(list())
  df <- tibble(id = as.integer(names(config_list)), value = as.Date(unlist(config_list)))
  mapped <- session_ids %>% inner_join(df, by = "id") %>% select(session_id, value) %>% distinct()
  setNames(as.list(mapped$value), as.character(mapped$session_id))
}

session_required_date_map <- build_session_constraint_map(date_restrictions)
session_excluded_date_map <- build_session_constraint_map(date_exclusions)

build_session_slot_constraint_map <- function(config_list) {
  if (length(config_list) == 0) return(list())
  df <- tibble(id = as.integer(names(config_list)), value = unlist(config_list))
  mapped <- session_ids %>% inner_join(df, by = "id") %>% select(session_id, value) %>% distinct()
  setNames(as.list(mapped$value), as.character(mapped$session_id))
}

session_required_slot_map <- build_session_slot_constraint_map(
  if (exists("slot_restrictions")) slot_restrictions else list()
)

# --- Swap safety check ---
swap_is_safe <- function(asgn, sess1, sess2, slot_col = "assigned_time_slot") {
  ts1 <- asgn[[slot_col]][asgn$session_id == sess1][1]
  ts2 <- asgn[[slot_col]][asgn$session_id == sess2][1]
  if (is.na(ts1) || is.na(ts2) || ts1 == ts2) return(TRUE)

  # PDW check
  if (sess1 %in% pdw_sessions && ts2 %in% pdw_slots) return(FALSE)
  if (sess2 %in% pdw_sessions && ts1 %in% pdw_slots) return(FALSE)

  s1 <- as.character(sess1); s2 <- as.character(sess2)

  # Slot restriction check
  sr1 <- session_required_slot_map[[s1]]
  if (!is.null(sr1) && ts2 != sr1) return(FALSE)
  sr2 <- session_required_slot_map[[s2]]
  if (!is.null(sr2) && ts1 != sr2) return(FALSE)

  # Date check
  d1 <- slot_to_date[[ts1]]; d2 <- slot_to_date[[ts2]]
  if (identical(d1, d2)) return(TRUE)

  req1 <- session_required_date_map[[s1]]
  if (!is.null(req1) && d2 != req1) return(FALSE)
  req2 <- session_required_date_map[[s2]]
  if (!is.null(req2) && d1 != req2) return(FALSE)
  excl1 <- session_excluded_date_map[[s1]]
  if (!is.null(excl1) && d2 == excl1) return(FALSE)
  excl2 <- session_excluded_date_map[[s2]]
  if (!is.null(excl2) && d1 == excl2) return(FALSE)

  TRUE
}

# --- Author-safe swap check ---
swap_is_author_safe <- function(asgn, sess1, sess2, slot_col = "time_slot") {
  if (!swap_is_safe(asgn, sess1, sess2, slot_col)) return(FALSE)
  slot1 <- asgn[[slot_col]][asgn$session_id == sess1]
  slot2 <- asgn[[slot_col]][asgn$session_id == sess2]
  if (slot1 == slot2) return(TRUE)

  a1 <- session_authors_map[[as.character(sess1)]]
  a2 <- session_authors_map[[as.character(sess2)]]
  if (!is.null(a1)) {
    others <- asgn$session_id[asgn[[slot_col]] == slot2 & asgn$session_id != sess2]
    if (length(others) > 0 && any(a1 %in% unlist(session_authors_map[as.character(others)])))
      return(FALSE)
  }
  if (!is.null(a2)) {
    others <- asgn$session_id[asgn[[slot_col]] == slot1 & asgn$session_id != sess1]
    if (length(others) > 0 && any(a2 %in% unlist(session_authors_map[as.character(others)])))
      return(FALSE)
  }
  TRUE
}

# --- Set seed ---
seed_val <- as.integer(SCHEDULE_SEED)
set.seed(seed_val)
cat("\nUsing random seed:", seed_val, "\n")

# =============================================================================
# Pre-assignment (constrained sessions first)
# =============================================================================

remaining_all_slots <- all_slots
pre_assigned <- tibble()

# Phase 1: Slot-restricted sessions
for (sess_id in sample(as.integer(names(session_required_slot_map)))) {
  req_slot <- session_required_slot_map[[as.character(sess_id)]]
  valid <- remaining_all_slots[remaining_all_slots == req_slot]
  if (length(valid) == 0) { warning("No slot ", req_slot, " for session ", sess_id); next }
  pre_assigned <- bind_rows(pre_assigned, tibble(session_id = as.double(sess_id), assigned_time_slot = sample(valid, 1)))
  remaining_all_slots <- remaining_all_slots[-which(remaining_all_slots == sample(valid, 1))[1]]
}
# Recompute remaining after phase 1
remaining_all_slots <- all_slots
for (i in seq_len(nrow(pre_assigned))) {
  s <- pre_assigned$assigned_time_slot[i]
  remaining_all_slots <- remaining_all_slots[-which(remaining_all_slots == s)[1]]
}

# Phase 2: PDW-conflicted sessions
for (sess_id in sample(pdw_sessions)) {
  if (as.double(sess_id) %in% pre_assigned$session_id) next
  valid <- remaining_all_slots[!remaining_all_slots %in% pdw_slots]
  excl_date <- session_excluded_date_map[[as.character(sess_id)]]
  if (!is.null(excl_date)) valid <- valid[slot_to_date[valid] != excl_date]
  req_date <- session_required_date_map[[as.character(sess_id)]]
  if (!is.null(req_date)) valid <- valid[slot_to_date[valid] == req_date]
  if (length(valid) == 0) { warning("No valid non-PDW slot for session ", sess_id); next }
  chosen <- sample(valid, 1)
  pre_assigned <- bind_rows(pre_assigned, tibble(session_id = as.double(sess_id), assigned_time_slot = chosen))
  remaining_all_slots <- remaining_all_slots[-which(remaining_all_slots == chosen)[1]]
}

# Phase 3: Date-restricted sessions
for (sess_id in sample(as.integer(names(session_required_date_map)))) {
  if (sess_id %in% pre_assigned$session_id) next
  req_date <- session_required_date_map[[as.character(sess_id)]]
  valid <- remaining_all_slots[slot_to_date[remaining_all_slots] == req_date]
  if (length(valid) == 0) { warning("No slot on ", req_date, " for session ", sess_id); next }
  chosen <- sample(valid, 1)
  pre_assigned <- bind_rows(pre_assigned, tibble(session_id = as.double(sess_id), assigned_time_slot = chosen))
  remaining_all_slots <- remaining_all_slots[-which(remaining_all_slots == chosen)[1]]
}

pre_assigned <- pre_assigned %>% left_join(session_categories, by = "session_id")

# Random assignment of remaining sessions
unconstrained <- session_categories %>%
  filter(!session_id %in% pre_assigned$session_id) %>%
  slice(sample(n()))

session_assignments <- bind_rows(
  pre_assigned,
  unconstrained %>% mutate(assigned_time_slot = sample(remaining_all_slots, nrow(unconstrained)))
) %>%
  distinct(session_id, .keep_all = TRUE)

cat(sprintf("Pre-assigned %d, randomly assigned %d\n", nrow(pre_assigned), nrow(unconstrained)))

# =============================================================================
# Conflict resolution
# =============================================================================

author_to_sessions <- all_authors_by_session %>%
  group_by(author_name) %>%
  summarise(sessions = list(session_id), .groups = "drop")

detect_conflicts <- function(asgn, slot_col = "assigned_time_slot") {
  conflicts <- list()
  for (i in seq_len(nrow(author_to_sessions))) {
    sessions <- author_to_sessions$sessions[[i]]
    slots <- asgn %>% filter(session_id %in% sessions) %>% select(session_id, !!sym(slot_col))
    dups <- slots %>% group_by(!!sym(slot_col)) %>% filter(n() > 1) %>% ungroup()
    if (nrow(dups) > 0) {
      for (ts in unique(dups[[slot_col]])) {
        conflicts[[length(conflicts) + 1]] <- list(
          author = author_to_sessions$author_name[i],
          slot = ts,
          sessions = dups$session_id[dups[[slot_col]] == ts]
        )
      }
    }
  }
  conflicts
}

try_swap <- function(asgn, sess1, sess2, slot_col = "assigned_time_slot") {
  idx1 <- which(asgn$session_id == sess1)
  idx2 <- which(asgn$session_id == sess2)
  tmp <- asgn[[slot_col]][idx1]
  asgn[[slot_col]][idx1] <- asgn[[slot_col]][idx2]
  asgn[[slot_col]][idx2] <- tmp
  asgn
}

resolve_conflicts <- function(asgn, slot_col = "assigned_time_slot", max_iter = 500) {
  conflicts <- detect_conflicts(asgn, slot_col)
  cat(sprintf("Initial conflicts: %d\n", length(conflicts)))
  iter <- 0
  while (length(conflicts) > 0 && iter < max_iter) {
    iter <- iter + 1; resolved <- FALSE
    for (conflict in conflicts) {
      author_sessions <- author_to_sessions %>%
        filter(author_name == conflict$author) %>% pull(sessions) %>% .[[1]]
      author_slots <- asgn %>% filter(session_id %in% author_sessions) %>%
        pull(!!sym(slot_col)) %>% unique()
      for (sess in conflict$sessions) {
        for (target_slot in setdiff(time_slot_order, author_slots)) {
          candidates <- asgn %>%
            filter(!!sym(slot_col) == target_slot, !session_id %in% author_sessions) %>%
            pull(session_id)
          for (cand in candidates) {
            if (!swap_is_safe(asgn, sess, cand, slot_col)) next
            test <- try_swap(asgn, sess, cand, slot_col)
            nc <- detect_conflicts(test, slot_col)
            if (length(nc) < length(conflicts)) {
              asgn <- test; conflicts <- nc; resolved <- TRUE
              cat(sprintf("  Iter %d: swapped %d <-> %d (conflicts: %d)\n", iter, sess, cand, length(nc)))
              break
            }
          }
          if (resolved) break
        }
        if (resolved) break
      }
      if (resolved) break
    }
    if (!resolved) { cat(sprintf("  Iter %d: no improvement\n", iter)); break }
  }
  if (length(conflicts) > 0) {
    cat(sprintf("\nRemaining conflicts: %d\n", length(conflicts)))
    for (c in conflicts) cat(sprintf("  %s in %s: sessions %s\n", c$author, c$slot, paste(c$sessions, collapse=", ")))
  } else {
    cat(sprintf("All conflicts resolved after %d iterations\n", iter))
  }
  asgn
}

cat("\n=== Resolving author conflicts ===\n")
session_assignments <- resolve_conflicts(session_assignments, "assigned_time_slot")

# =============================================================================
# Category spread optimization
# =============================================================================

cat("\n=== Optimizing category spread ===\n")

cat_score <- function(asgn, slot_col = "assigned_time_slot") {
  sc <- asgn %>% count(!!sym(slot_col), category, name = "n") %>% filter(n > 1)
  if (nrow(sc) == 0) return(0L)
  n_multi <- sc %>% count(!!sym(slot_col), name = "nd") %>% filter(nd > 1) %>% nrow()
  n_multi * 1000L + sum(sc$n - 1L)
}

optimize_category_spread <- function(asgn, slot_col = "assigned_time_slot", max_iter = 1000) {
  score <- cat_score(asgn, slot_col)
  cat(sprintf("Category score: %d\n", score))
  iter <- 0; improved <- TRUE
  while (improved && iter < max_iter && score > 0) {
    improved <- FALSE; iter <- iter + 1
    clustered <- asgn %>%
      add_count(!!sym(slot_col), category, name = "sc") %>%
      filter(sc > 1) %>% arrange(desc(sc))
    if (nrow(clustered) == 0) break
    found <- FALSE
    for (i in seq_len(nrow(clustered))) {
      if (found) break
      sess1 <- clustered$session_id[i]
      for (sess2 in asgn$session_id[asgn$session_id != sess1]) {
        if (!swap_is_author_safe(asgn, sess1, sess2, slot_col)) next
        test <- try_swap(asgn, sess1, sess2, slot_col)
        ns <- cat_score(test, slot_col)
        if (ns < score) {
          asgn <- test; score <- ns; improved <- TRUE; found <- TRUE
          cat(sprintf("  Iter %d: swapped %d <-> %d (score: %d)\n", iter, sess1, sess2, score))
          break
        }
      }
    }
    if (!found) break
  }
  cat(sprintf("Final category score: %d after %d iterations\n", score, iter))
  asgn
}

session_assignments <- optimize_category_spread(session_assignments, "assigned_time_slot")

# =============================================================================
# Assign rooms and build final schedule
# =============================================================================

session_assignments <- session_assignments %>%
  group_by(assigned_time_slot) %>%
  arrange(category) %>%
  mutate(room_index = row_number()) %>%
  ungroup()

room_lookup <- session_slots %>%
  group_by(time_slot) %>%
  mutate(room_index = row_number()) %>%
  ungroup() %>%
  select(time_slot, room_index, room, date, day, start_time, end_time, time_order)

session_assignments <- session_assignments %>%
  left_join(room_lookup, by = c("assigned_time_slot" = "time_slot", "room_index")) %>%
  select(session_id, session_name, category, time_slot = assigned_time_slot,
         room, date, day, start_time, end_time, time_order)

# =============================================================================
# Post-assignment constraint enforcement
# =============================================================================

slot_cols <- c("time_slot", "room", "date", "day", "start_time", "end_time", "time_order")

try_swap_full <- function(asgn, sess1, sess2) {
  idx1 <- which(asgn$session_id == sess1)
  idx2 <- which(asgn$session_id == sess2)
  tmp <- asgn[idx1, slot_cols]
  asgn[idx1, slot_cols] <- asgn[idx2, slot_cols]
  asgn[idx2, slot_cols] <- tmp
  asgn
}

# Date exclusions
if (length(date_exclusions) > 0) {
  cat("\n=== Enforcing date exclusions ===\n")
  excl_df <- tibble(id = as.integer(names(date_exclusions)), excluded_date = as.Date(unlist(date_exclusions)))
  sess_excl <- session_ids %>% inner_join(excl_df, by = "id") %>% select(session_id, excluded_date) %>% distinct()
  for (i in seq_len(nrow(sess_excl))) {
    sid <- sess_excl$session_id[i]; ed <- sess_excl$excluded_date[i]
    row <- session_assignments %>% filter(session_id == sid)
    if (nrow(row) == 0 || as.Date(row$date) != ed) next
    cands <- session_assignments %>% filter(as.Date(date) != ed, session_id != sid)
    if (sid %in% pdw_sessions) cands <- cands %>% filter(!time_slot %in% pdw_slots)
    if (nrow(cands) > 0) {
      session_assignments <- try_swap_full(session_assignments, sid, cands$session_id[1])
      cat(sprintf("  Session %d moved off %s\n", sid, format(ed)))
    }
  }
}

# PDW enforcement
cat("\n=== Enforcing PDW exclusions ===\n")
for (sid in pdw_sessions) {
  row <- session_assignments %>% filter(session_id == sid)
  if (nrow(row) == 0 || !row$time_slot %in% pdw_slots) next
  cands <- session_assignments %>%
    filter(!time_slot %in% pdw_slots, !session_id %in% pdw_sessions)
  if (nrow(cands) > 0) {
    session_assignments <- try_swap_full(session_assignments, sid, cands$session_id[1])
    cat(sprintf("  Session %d moved out of PDW slot\n", sid))
  }
}

# Post-constraint conflict resolution
cat("\n=== Post-constraint conflict resolution ===\n")
conflicts <- detect_conflicts(session_assignments, "time_slot")
cat(sprintf("Conflicts: %d\n", length(conflicts)))
iter <- 0
while (length(conflicts) > 0 && iter < 500) {
  iter <- iter + 1; resolved <- FALSE
  for (conflict in conflicts) {
    author_sessions <- author_to_sessions %>%
      filter(author_name == conflict$author) %>% pull(sessions) %>% .[[1]]
    for (sess in conflict$sessions) {
      for (ts in setdiff(time_slot_order, session_assignments %>%
        filter(session_id %in% author_sessions) %>% pull(time_slot) %>% unique())) {
        cands <- session_assignments %>%
          filter(time_slot == ts, !session_id %in% author_sessions) %>% pull(session_id)
        for (cand in cands) {
          if (!swap_is_safe(session_assignments, sess, cand, "time_slot")) next
          test <- try_swap_full(session_assignments, sess, cand)
          nc <- detect_conflicts(test, "time_slot")
          if (length(nc) < length(conflicts)) {
            session_assignments <- test; conflicts <- nc; resolved <- TRUE
            cat(sprintf("  Iter %d: swapped %d <-> %d (conflicts: %d)\n", iter, sess, cand, length(nc)))
            break
          }
        }
        if (resolved) break
      }
      if (resolved) break
    }
    if (resolved) break
  }
  if (!resolved) break
}

# Final category spread
cat("\n=== Final category spread ===\n")
session_assignments <- optimize_category_spread(session_assignments, "time_slot")

# =============================================================================
# Merge with session-ids and write output
# =============================================================================

schedule <- session_ids %>%
  left_join(
    session_assignments %>%
      select(session_id, time_slot, room, date, day, start_time, end_time, time_order),
    by = "session_id"
  ) %>%
  arrange(time_order, room, paper_order)

write_csv(schedule, here("data", "schedule.csv"))

cat("\n=== Final summary ===\n")
schedule %>%
  distinct(session_id, time_slot, day) %>%
  count(time_slot, day) %>%
  print()
