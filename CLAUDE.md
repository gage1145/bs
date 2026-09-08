# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A [Quarto](https://quarto.org/) website — a personal blog documenting the author's participation in a bible study, written from an agnostic-atheist perspective. It is a static site (no application code, no build scripts, no package manager); all content lives in `.qmd` (Quarto Markdown) files. 

You serve primarily as a writing reviewer, fact checker, and biblical researcher as needed.

## Commands

Quarto CLI must be installed (https://quarto.org/docs/get-started/) and available on PATH.

- `quarto preview` — serve the site locally with live reload while editing.
- `quarto render` — build the static site into `_site/` (gitignored).
- `quarto check` — verify the Quarto installation/environment if rendering misbehaves.
- `Rscript scripts/build-bible.R` — regenerate the Bible reference pages from the EPUB.
  Only needed if the EPUB or the generator changes; the output is committed. Requires
  `xml2` and `stringr` (`renv::restore()`, or `renv::install(c("xml2","stringr"))`).

There is no test suite, linter, or CI config in this repo.

## Architecture

- `_quarto.yml` — site-level config: project type (`website`), navbar links, and the HTML theme/CSS (`format.html`). Changing site title, nav, or global theme happens here.
- `index.qmd` — the home page; renders as a post listing (`listing.contents: posts`) sorted by date descending, with categories enabled.
- `posts/` — each subdirectory is one blog post, containing an `index.qmd` with YAML frontmatter (`title`, `author`, `date`, `categories`, `image`). New posts are added by creating a new `posts/<slug>/index.qmd`.
- `posts/_metadata.yml` — shared frontmatter defaults applied to every post (currently `freeze: true` for computational output and `title-block-banner: true`).
- `about.qmd` — About page using Quarto's `jolla` about-page template.
- `styles.css` — custom CSS layered on top of the `yeti` Bootstrap theme set in `_quarto.yml`.
- `_site/` and `.quarto/` — generated build output and Quarto's internal cache; both gitignored, never edit directly.

### Bible reference pages

`resources/bible.epub` is *The New Oxford Annotated Bible with Apocrypha*, 5th ed. (OUP, 2018),
used as the study's reference text.

- `scripts/build-bible.R` — one-time generator. Unpacks the EPUB once and transforms each spine
  document (one per book) into a static page. **Quarto never runs this**; the EPUB is immutable, so
  nothing is extracted at render time and no page executes code.
- `bible/*.qmd` — generated, one page per book/essay. Markdown headings interleaved with
  ` ```{=html} ` raw blocks so the publisher's markup (verse numbers, small caps, poetry
  indentation, annotations, footnotes) survives intact and cross-references resolve between pages.
- `bible/bible.css` — generated from the EPUB's own stylesheet. Loaded only on `bible/` pages via
  `bible/_metadata.yml`, so its rules cannot leak into the rest of the site.
- `_bible-sidebar.yml` — generated sidebar, merged in through `metadata-files` in `_quarto.yml`.

Everything under `bible/`, plus `_bible-sidebar.yml`, is generated output. Edit
`scripts/build-bible.R` and regenerate rather than editing those files by hand.

## Content conventions

- Post dates in frontmatter use `YYYY-MM-DD` and should reflect the actual/intended publish date.
- Posts use the `categories` frontmatter field (e.g. `[post]`) for the listing page's category filter.
- Tone: first-person, reflective essay style, written for the author's mother's bible study group.
