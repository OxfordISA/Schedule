# =============================================================================
# Step 0: Clean raw submissions → data/submissions.csv
# =============================================================================
# Input:  data/submissions_raw.csv (exported from conference management system)
#         data/self-sessions.csv   (self-organized panel papers)
# Output: data/submissions.csv    (cleaned, with type classification)
# =============================================================================

library(janitor)
source(here::here("code", "config.R"))

# --- Read raw submissions ---

raw <- read_csv(
  here("data", "submissions_raw.csv"),
  show_col_types = FALSE
) %>%
  clean_names()

submissions <- raw %>%
  select(
    id         = paper_id,
    authors,
    contact_author = primary_contact_author_name,
    contact_email  = primary_contact_author_email,
    author_names,
    author_emails,
    category   = primary_subject_area,
    award      = q1_award_consideration,
    pdw        = q2_professional_development_workshop_pdw,
    n_files    = number_of_files,
    title      = paper_title,
    abstract
  ) %>%
  mutate(pdw = as.numeric(pdw == "Yes" & !is.na(pdw)))

# --- Fix casing in author/affiliation strings ---
# Title-case the authors field, then fix known acronyms and prepositions.
# Add institution-specific corrections as needed for your conference.

acronym_fixes <- c(
  "J.p."  = "J.P.",  " Of "  = " of ",  " On "  = " on ",
  " The " = " the ", " And " = " and ", " At "  = " at ",
  "Mit"   = "MIT",   "Icic"  = "ICIC",  "Uc "   = "UC ",
  "Ucla"  = "UCLA",  "Us "   = "US ",   " For " = " for ",
  "Llc"   = "LLC",   "Ut-Dallas" = "UT-Dallas",
  "Ibm"   = "IBM",   "Imf"   = "IMF",   "Itam"  = "ITAM",
  "Cuny"  = "CUNY",  "Cspo"  = "CSPO",  "Insead" = "INSEAD",
  "Iit"   = "IIT",   "Iim"   = "IIM",   "Eth"   = "ETH",
  "Cmu"   = "CMU",   "Arua"  = "ARUA",  "P.c."  = "P.C.",
  "Soas"  = "SOAS",  "Dc,"   = "DC,",   "Usa"   = "USA",
  "Feup"  = "FEUP",  "Icd "  = "ICD ",
  "Cornell Ilr School" = "Cornell ILR School",
  "Univeristy" = "University",
  "Institute If Management" = "Institute of Management"
)

submissions <- submissions %>%
  mutate(
    authors = str_to_title(authors),
    authors = str_replace_all(authors, "\\*", ""),
    contact_author = str_to_title(contact_author)
  )

for (from in names(acronym_fixes)) {
  submissions <- submissions %>%
    mutate(authors = str_replace_all(authors, fixed(from), acronym_fixes[[from]]))
}

# Clean up stray whitespace characters
submissions <- submissions %>%
  mutate(
    authors = str_replace_all(authors, "\t", " "),
    authors = str_replace_all(authors, "\\s+", " "),
    authors = str_trim(authors)
  )

# --- Recode award categories ---

awards_df <- tibble(
  award      = names(award_map),
  award_code = unname(award_map)
)

submissions <- submissions %>%
  left_join(awards_df, by = "award") %>%
  select(-award) %>%
  rename(award = award_code)

# --- Apply recategorizations ---

if (length(recategorize_ids) > 0) {
  recat_df <- tibble(
    id      = as.integer(names(recategorize_ids)),
    new_cat = unlist(recategorize_ids)
  )
  submissions <- submissions %>%
    left_join(recat_df, by = "id") %>%
    mutate(category = if_else(!is.na(new_cat), new_cat, category)) %>%
    select(-new_cat)
}

# --- Classify submission types ---

submissions <- submissions %>%
  mutate(
    type = case_when(
      id %in% self_organized_panel_ids ~ "self_organized_panel",
      id %in% dissertation_ids         ~ "dissertation",
      TRUE                             ~ "paper"
    )
  )

# --- Merge self-organized panel papers ---
# Self-organized panels have one row per paper in self-sessions.csv;
# these replace the single-row entry from raw submissions.

self_sessions <- read_csv(
  here("data", "self-sessions.csv"),
  show_col_types = FALSE
) %>%
  clean_names() %>%
  left_join(awards_df, by = "award") %>%
  select(-award) %>%
  rename(award = award_code) %>%
  select(id, authors, contact_author, contact_email, author_names,
         author_emails, category, award, pdw, n_files, title, abstract)

submissions <- submissions %>%
  filter(!id %in% unique(self_sessions$id)) %>%
  bind_rows(self_sessions)

# --- Filter out rejected, withdrawn, and panel discussion submissions ---

submissions <- submissions %>%
  filter(!id %in% reject_ids) %>%
  filter(!id %in% withdraw_ids) %>%
  filter(!id %in% panel_discussion_ids)

# --- Write output ---

submissions %>%
  select(id, type, authors, category, award, contact_author, contact_email,
         author_names, author_emails, title, abstract, pdw) %>%
  arrange(category, id) %>%
  write_csv(here("data", "submissions.csv"))

cat(sprintf(
  "Written %d submissions to data/submissions.csv (%d papers, %d self-organized panels, %d dissertations)\n",
  nrow(submissions),
  sum(submissions$type == "paper"),
  sum(submissions$type == "self_organized_panel"),
  sum(submissions$type == "dissertation")
))
