# =============================================================================
# Step 0b: Export per-track CSVs for track chairs to organize into sessions
# =============================================================================
# Run this AFTER 0clean.R. Produces one CSV per track in data/sessions/draft/.
# Track chairs fill in session_id, session_name, and paper_order columns,
# then save finalized files into data/sessions/.
#
# Input:  data/submissions.csv
# Output: data/sessions/draft/<track_slug>.csv (one per track)
# =============================================================================

source(here::here("code", "config.R"))

# Only export papers (not dissertations or self-organized panels)
papers <- submissions %>%
  filter(type == "paper")

draft_dir <- here("data", "sessions", "draft")
if (!dir.exists(draft_dir)) dir.create(draft_dir, recursive = TRUE)

make_slug <- function(cat_name) {
  cat_name %>%
    str_to_lower() %>%
    str_replace_all("[^a-z0-9]+", "_") %>%
    str_replace_all("_+$", "")
}

for (cat_name in sort(unique(papers$category))) {
  cat_papers <- papers %>%
    filter(category == cat_name) %>%
    select(id, title, authors, abstract) %>%
    mutate(
      session_id = NA_integer_,
      session_name = NA_character_,
      paper_order = NA_integer_
    ) %>%
    select(id, session_id, session_name, paper_order, title, authors, abstract) %>%
    arrange(id)

  slug <- make_slug(cat_name)
  outfile <- file.path(draft_dir, paste0(slug, ".csv"))
  write_csv(cat_papers, outfile)
  cat(sprintf("  %s: %d papers\n", slug, nrow(cat_papers)))
}

cat(sprintf(
  "\nExported %d tracks to data/sessions/draft/\n",
  n_distinct(papers$category)
))
cat("Track chairs should:\n")
cat("  1. Open each CSV\n")
cat("  2. Fill in session_id, session_name, paper_order for each paper\n")
cat("  3. Save finalized files to data/sessions/ (removing the draft/ subfolder)\n")
cat("  4. The final CSVs only need: id, session_id, session_name, paper_order\n")
cat("     (title/authors/abstract columns can be kept for reference or removed)\n")
