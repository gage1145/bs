#!/usr/bin/env Rscript
#
# Generates bible/*.qmd from resources/bible.epub.
#
# Run manually:  Rscript scripts/build-bible.R
#
# Quarto never invokes this. The EPUB is immutable, so the extraction happens
# once and the site then renders static markup with zero code execution.

suppressPackageStartupMessages({
  library(xml2)
  library(stringr)
})

epub_path <- "resources/bible.epub"
out_dir   <- "bible"
img_dir   <- file.path(out_dir, "images")
sidebar_f <- "_bible-sidebar.yml"

stopifnot(file.exists(epub_path))

# ---------------------------------------------------------------- helpers ----

write_utf8 <- function(lines, path) {
  con <- file(path, open = "wb")
  on.exit(close(con))
  writeLines(enc2utf8(lines), con, useBytes = TRUE, sep = "\n")
}

yq <- function(x) {                       # quote a string for YAML
  x <- str_replace_all(x, "\\\\", "\\\\\\\\")
  x <- str_replace_all(x, '"', '\\\\"')
  paste0('"', x, '"')
}

# A leading "(A)" labels one of the Apocrypha groupings and has to survive; a
# parenthetical after the title proper ("1 Samuel (1 Kingdoms in Greek)") is an
# aside that belongs in the subtitle.
strip_paren <- function(x) str_squish(str_replace_all(x, "(?<=\\S)\\s*\\([^)]*\\)", ""))

first_paren <- function(x) {
  m <- str_match(x, "(?<=\\S)\\s*\\(([^)]*)\\)")
  if (is.na(m[, 2])) NA_character_ else str_squish(m[, 2])
}

QUOTES <- "[‘’“”']"

slugify <- function(x) {
  x <- strip_paren(x)
  x <- str_replace_all(x, QUOTES, "")
  x <- tolower(x)
  x <- str_replace_all(x, "[^a-z0-9]+", "-")
  x <- str_replace_all(x, "(^-+)|(-+$)", "")
  if (nchar(x) > 60) x <- str_replace(str_sub(x, 1, 60), "-[^-]*$", "")   # whole words
  str_replace_all(x, "-+$", "")
}

href_file   <- function(h) sub("#.*$", "", h)
href_anchor <- function(h) if (grepl("#", h, fixed = TRUE)) sub("^[^#]*#", "", h) else ""

# ------------------------------------------------------------- unpack once ---

work <- file.path(tempdir(), "noab-build")
if (dir.exists(work)) unlink(work, recursive = TRUE)
dir.create(work, recursive = TRUE)
message("Unpacking EPUB ...")
utils::unzip(epub_path, exdir = work)
oebps <- file.path(work, "OEBPS")
stopifnot(dir.exists(oebps))

# ------------------------------------------------------- spine (page order) --

opf <- read_xml(file.path(oebps, "content.opf"))
xml_ns_strip(opf)
manifest <- xml_find_all(opf, "//manifest/item")
man_map  <- setNames(xml_attr(manifest, "href"), xml_attr(manifest, "id"))
spine_id <- xml_attr(xml_find_all(opf, "//spine/itemref"), "idref")
spine    <- unname(man_map[spine_id])
spine    <- spine[!is.na(spine) & grepl("\\.x?html$", spine)]
message("Spine documents: ", length(spine))

# ------------------------------------------------------------ nav (the toc) --

nav <- read_html(file.path(oebps, "navigation.xhtml"))
toc <- xml_find_first(nav, "//*[@id='toc']")
stopifnot(!inherits(toc, "xml_missing"))

parse_items <- function(ol) {
  lapply(xml_find_all(ol, "./li"), function(li) {
    a  <- xml_find_first(li, "./a")
    ch <- xml_find_first(li, "./ol")
    list(
      title    = if (inherits(a, "xml_missing")) NA_character_ else str_squish(xml_text(a)),
      href     = if (inherits(a, "xml_missing")) NA_character_ else xml_attr(a, "href"),
      children = if (inherits(ch, "xml_missing")) list() else parse_items(ch)
    )
  })
}
tree <- parse_items(xml_find_first(toc, ".//ol"))

# Flatten in document order, so the FIRST entry referencing a file owns its page.
flat <- list()
walk <- function(items, parent) {
  for (it in items) {
    flat[[length(flat) + 1L]] <<- list(title = it$title, href = it$href, parent = parent)
    if (length(it$children)) walk(it$children, it$title)
  }
}
walk(tree, NA_character_)
message("Nav entries: ", length(flat))

# ------------------------------------------------------------------ slugs ----

pages <- list()   # file -> list(slug, title, subtitle, owner_href)
used  <- character()

# These titles recur throughout the nav, so they are always parent-qualified
# rather than left to collide.
GENERIC <- c("introduction", "contents", "preface", "index", "glossary",
             "prologue", "epilogue", "appendix")

claim <- function(base, parent) {
  s <- slugify(base)
  if (!nzchar(s)) s <- "page"
  if ((s %in% used || s %in% GENERIC) && !is.na(parent)) {
    s <- paste(slugify(parent), s, sep = "-")
  }
  if (s %in% used) {
    i <- 2L
    while (paste0(s, "-", i) %in% used) i <- i + 1L
    s <- paste0(s, "-", i)
  }
  used <<- c(used, s)
  s
}

for (e in flat) {
  if (is.na(e$href)) next
  f <- href_file(e$href)
  if (!nzchar(f) || !is.null(pages[[f]])) next
  pages[[f]] <- list(
    slug       = claim(e$title, e$parent),
    title      = strip_paren(e$title),
    subtitle   = first_paren(e$title),
    owner_href = e$href
  )
}

# Spine documents the nav never mentions still get a page.
for (f in spine) {
  if (!is.null(pages[[f]])) next
  d <- read_html(file.path(oebps, f))
  h <- xml_find_first(d, "//h1|//h2|//title")
  t <- if (inherits(h, "xml_missing")) f else str_squish(xml_text(h))
  if (!nzchar(t)) t <- f
  pages[[f]] <- list(slug = claim(t, NA_character_), title = strip_paren(t),
                     subtitle = NA_character_, owner_href = NA_character_)
}

filemap <- vapply(pages, function(p) p$slug, character(1))

# --------------------------------------------------------------- transform ---

TITLE_HEADS <- c("chaptertitle", "chaptertitleba", "parttitle", "parttitlea",
                 "fm_title", "bm_title", "halftitle", "booktitle", "booktitlea",
                 "booktitleb", "booktitleba", "booktitlebaa", "partnum")
SECTION_HEADS <- c("h1ib", "h1iba", "h1ibaa", "h1iab", "h1k", "h2ib", "h2")
ANNOT_HEADS   <- c("h1kj", "h1kja")

unwrap <- function(d) {
  for (k in xml_children(d)) xml_add_sibling(d, k, .where = "before")
  xml_remove(d)
}

build_page <- function(f) {
  meta <- pages[[f]]
  doc  <- read_html(file.path(oebps, f))
  node <- xml_find_first(doc, "//div[@class='chapter']")
  if (inherits(node, "xml_missing")) node <- xml_find_first(doc, "//body")
  if (inherits(node, "xml_missing")) return(invisible(NULL))

  # The book title becomes the page title; drop the in-body duplicate.
  heads <- xml_find_all(node, ".//h1|.//h2")
  if (length(heads)) {
    cls <- xml_attr(heads[[1]], "class")
    if (!is.na(cls) && cls %in% TITLE_HEADS) xml_remove(heads[[1]])
  }

  # Lift the introduction's headings to the top level so they can become real
  # markdown headings, and therefore real TOC entries.
  for (d in xml_find_all(node, ".//div[@class='chapterfrontmatter']")) unwrap(d)

  # The EPUB marks up annotation blocks as <h1>. They are not headings.
  annot_xp <- paste0(".//h1[@class='", ANNOT_HEADS, "']", collapse = "|")
  for (n in xml_find_all(node, annot_xp)) xml_set_name(n, "div")

  # Real section headings are <h1> at every nesting level. Top-level ones become
  # markdown headings below; demote the rest so a book page has one <h1>.
  sect_xp <- paste0(".//h1[@class='", SECTION_HEADS, "']", collapse = "|")
  for (n in xml_find_all(node, sect_xp)) xml_set_name(n, "h2")

  # Point cross-references at the generated pages.
  for (a in xml_find_all(node, ".//a[@href]")) {
    h <- xml_attr(a, "href")
    if (is.na(h) || !nzchar(h) || startsWith(h, "#") || grepl("^[a-zA-Z]+:", h)) next
    s <- filemap[[href_file(h)]]
    if (is.null(s) || is.na(s)) {
      xml_set_attr(a, "href", NULL)          # no page for the target: render as text
    } else {
      anc <- href_anchor(h)
      xml_set_attr(a, "href",
                   paste0(s, ".html", if (nzchar(anc)) paste0("#", anc) else ""))
    }
  }

  # Emit: markdown headings interleaved with verbatim raw-HTML blocks.
  parts <- character()
  buf   <- character()
  flush <- function() {
    if (length(buf)) {
      parts <<- c(parts, "```{=html}", buf, "```", "")
      buf   <<- character()
    }
  }
  for (ch in xml_children(node)) {
    cls <- xml_attr(ch, "class")
    if (xml_name(ch) %in% c("h1", "h2") && !is.na(cls) && cls %in% SECTION_HEADS) {
      txt <- str_squish(xml_text(ch))
      if (!nzchar(txt)) next
      flush()
      id <- xml_attr(ch, "id")
      parts <- c(parts,
                 paste0("## ", txt, if (!is.na(id)) paste0(" {#", id, "}") else ""),
                 "")
    } else {
      buf <- c(buf, as.character(ch))
    }
  }
  flush()

  yaml <- c("---", paste0("title: ", yq(meta$title)))
  if (!is.na(meta$subtitle)) yaml <- c(yaml, paste0("subtitle: ", yq(meta$subtitle)))
  yaml <- c(yaml, "---", "")

  write_utf8(c(yaml, parts), file.path(out_dir, paste0(meta$slug, ".qmd")))
}

# ------------------------------------------------------------------ build ----

if (dir.exists(out_dir)) unlink(out_dir, recursive = TRUE)
dir.create(img_dir, recursive = TRUE)

message("Writing pages ...")
for (i in seq_along(spine)) {
  build_page(spine[i])
  if (i %% 20 == 0) message("  ", i, "/", length(spine))
}

# ----------------------------------------------------------------- assets ----

src_img <- file.path(oebps, "images")
if (dir.exists(src_img)) {
  file.copy(list.files(src_img, full.names = TRUE), img_dir, overwrite = TRUE)
  message("Images: ", length(list.files(img_dir)))
}

# The publisher stylesheet already covers every class the EPUB uses, and it only
# loads on bible/ pages, so class rules cannot leak into the rest of the site.
# The handful of bare element rules do need scoping to Quarto's content area.
css <- paste(readLines(file.path(oebps, "OUP_Styles.css"), warn = FALSE), collapse = "\n")
css <- str_remove_all(css, "(?s)/\\*.*?\\*/")
rules <- str_match_all(css, "(?s)([^{}]+)\\{([^{}]*)\\}")[[1]]
retagged <- c(SECTION_HEADS, ANNOT_HEADS)
out_css <- character()
for (i in seq_len(nrow(rules))) {
  sels <- str_squish(str_split(rules[i, 2], ",")[[1]])
  sels <- sels[nzchar(sels)]
  sels <- sels[sels != "body"]                                # fights Bootstrap
  sels <- ifelse(grepl("^[a-z]+$", sels), paste("main.content", sels), sels)
  # build_page() retags these classes (annotations to <div>, section headings to
  # <h2>), so drop the element qualifier and let the class carry the styling.
  sels <- str_replace(sels, paste0("^h1\\.(", paste(retagged, collapse = "|"), ")$"), ".\\1")
  if (!length(sels)) next
  body <- str_squish(rules[i, 3])
  if (!nzchar(body)) next
  out_css <- c(out_css, paste0(paste(sels, collapse = ", "), " { ", body, " }"))
}
write_utf8(c("/* Derived from OUP_Styles.css inside resources/bible.epub.",
             "   Generated by scripts/build-bible.R - do not edit by hand. */",
             out_css),
           file.path(out_dir, "bible.css"))
message("CSS rules: ", length(out_css))

write_utf8(c(
  "# Applies to every generated Bible page.",
  "# Generated by scripts/build-bible.R - do not edit by hand.",
  "css:",
  "  - ../styles.css",
  "  - bible.css",
  "toc: true",
  "toc-depth: 2",
  "title-block-banner: false",
  "page-layout: article"
), file.path(out_dir, "_metadata.yml"))

# ---------------------------------------------------------------- sidebar ----

# The nav entry that owns a file links to the page; every other entry pointing
# into that file becomes an in-page anchor.
link_for <- function(it) {
  if (is.na(it$href)) return(NULL)
  p <- pages[[href_file(it$href)]]
  if (is.null(p)) return(NULL)
  if (identical(it$href, p$owner_href)) return(paste0(out_dir, "/", p$slug, ".qmd"))
  anc <- href_anchor(it$href)
  paste0(out_dir, "/", p$slug, ".html", if (nzchar(anc)) paste0("#", anc) else "")
}

emit <- function(items, indent, parent_file) {
  out <- character()
  pad <- strrep(" ", indent)
  for (j in seq_along(items)) {
    it <- items[[j]]
    if (is.na(it$title)) next
    f <- if (is.na(it$href)) NA_character_ else href_file(it$href)
    # A section's own page is already linked from the section header, so drop
    # the redundant leading "Introduction" pointing back at the same file.
    if (j == 1L && !length(it$children) && identical(f, parent_file) &&
        grepl("^introduction", tolower(it$title))) next
    href  <- link_for(it)
    label <- strip_paren(it$title)
    if (length(it$children)) {
      out <- c(out, paste0(pad, "- section: ", yq(label)))
      if (!is.null(href)) out <- c(out, paste0(pad, "  href: ", href))
      out <- c(out, paste0(pad, "  contents:"), emit(it$children, indent + 6L, f))
    } else if (!is.null(href)) {
      out <- c(out,
               paste0(pad, "- text: ", yq(label)),
               paste0(pad, "  href: ", href))
    }
  }
  out
}

write_utf8(c(
  "# Generated by scripts/build-bible.R - do not edit by hand.",
  "website:",
  "  sidebar:",
  "    - id: bible",
  '      title: "The New Oxford Annotated Bible"',
  "      style: floating",
  "      collapse-level: 1",
  "      contents:",
  paste0("        - ", out_dir, "/index.qmd"),
  emit(tree, 8L, NA_character_)
), sidebar_f)

# ------------------------------------------------------------ landing page ---

rel <- function(h) sub(paste0("^", out_dir, "/"), "", h)

idx <- c("---", 'title: "The New Oxford Annotated Bible"', "toc: false", "---", "",
  "Reference text for this study: *The New Oxford Annotated Bible with Apocrypha*,",
  "5th edition (Michael Coogan, Marc Z. Brettler, Carol A. Newsom, and Pheme",
  "Perkins, eds.), Oxford University Press, 2018. The translation is the New",
  "Revised Standard Version; the introductions, annotations, and essays are the",
  "editors'.", "",
  "Use the sidebar to navigate, or the index below.", "")

# Nested bullets, so the index follows the nav to whatever depth it goes (the
# Apocrypha groupings are a level deeper than everything else).
bullets <- function(items, depth) {
  out <- character()
  pad <- strrep("  ", depth)
  for (it in items) {
    if (is.na(it$title)) next
    h     <- link_for(it)
    label <- strip_paren(it$title)
    out <- c(out,
             if (is.null(h)) paste0(pad, "- ", label)
             else paste0(pad, "- [", label, "](", rel(h), ")"),
             bullets(it$children, depth + 1L))
  }
  out
}

front <- FALSE
for (top in tree) {
  if (is.na(top$title)) next
  if (length(top$children)) {
    idx   <- c(idx, paste0("## ", strip_paren(top$title)), "",
               bullets(top$children, 0L), "")
    front <- FALSE
  } else {
    if (!front) { idx <- c(idx, "## Front Matter", ""); front <- TRUE }
    idx <- c(idx, bullets(list(top), 0L))
  }
}
write_utf8(idx, file.path(out_dir, "index.qmd"))

message("Done: ", length(list.files(out_dir, pattern = "\\.qmd$")), " pages in ",
        out_dir, "/")
