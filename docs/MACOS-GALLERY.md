# Paper NAS for Mac

A tour of the native app, from choosing a paper to recording a research decision. SwiftUI provides navigation and forms, PDFKit displays original documents, and the reading view renders mathematical text locally with KaTeX.

[Project overview](../README.md) · [Build the Mac app](../macOS/README.md) · [Web gallery](SCREENSHOTS.md) · [中文介绍](README.zh-CN.md)

These 17 screenshots show the running 0.5.0 Mac client on 2026-10-26. Interface labels are currently primarily Chinese. All paper titles, source documents, analyses, and research records are synthetic demonstration content; [capture details](#about-these-captures) are below. Click any image to inspect it at full size.

## A library you can browse

Use a list for titles and summaries, or switch to a visual grid with PDF and figure previews. Groups stay in the sidebar alongside the library, candidate queue, research workspace, and tasks.

![Native Mac library in list view](images/macos-library-light.jpg)

![Native Mac library in grid view with paper and figure previews](images/macos-library-grid.jpg)

## A queue before the library

Keep candidates separate while deciding what to read. The sample queue contains three metadata-only records, so their preview placeholders are expected; the library above contains imported PDFs.

![Native candidate queue with three synthetic papers](images/macos-candidates.jpg)

## Reading with structure

An analysis opens as a reading document with chapter navigation, clear headings, and citations beside the relevant statements. Move between the analysis, original PDF, extracted text, and figures from the toolbar.

![Native analysis reader with a table of contents and source citation controls](images/macos-analysis.jpg)

## Focus on the page

Focus mode hides the contents sidebar while keeping chapter navigation available. The sample passage includes an inline equation rendered locally and source buttons beneath each cited finding.

![Focused reading with an inline equation and exact-source citation buttons](images/macos-focus-reading.jpg)

## Follow a citation to its source

Open a citation and locate its original passage. The extracted-text view highlights the quoted words and keeps the source page and evidence action nearby.

![Source text with the cited passage highlighted and its page shown](images/macos-source-text.jpg)

## The original PDF, with your notes

PDFKit displays the source document beside page-linked notes. Notes retain the PDF version and page; native text selection and region anchors keep observations connected to the original material. The diagram below is a conceptual sample.

![Native PDF reader beside a saved note and conceptual workflow diagram](images/macos-pdf-notes-light.jpg)

## Figures as source material

Inspect an extracted figure at a useful size, open its source page, download the original asset, or save it to a research question.

![Native figure reader with the original diagram and source actions](images/macos-figures.jpg)

If an extracted region needs adjustment, a native sheet previews the source page and selected rectangle. Position and size controls define the region sent to the background repair operation.

![Native figure correction sheet with a blue region on the original PDF page](images/macos-figure-correction.jpg)

## Save evidence while reading

Choose a research question, preserve the source quotation, and add your own comment. This example saves a figure to the same question used in the following research views.

![Native evidence form with a research question, source quotation, and personal comment](images/macos-save-evidence.jpg)

## A question with its evidence

The research workspace brings linked papers and source evidence together. The sample question contains three papers, three text passages, and one figure captured from the reader.

![Native research workspace with linked papers and four source evidence items](images/macos-research-evidence.jpg)

## A judgment and a way to check it

Write a current judgment, then record a verification plan with assumptions, method, baseline, measures, and success criteria. These are research records; Paper NAS does not execute experiments.

![Native research workspace showing a judgment and a detailed verification plan](images/macos-research-plans.jpg)

## Results and evolving understanding

Record results from work performed outside the app and preserve a snapshot of what you currently understand. This demonstration explicitly records that no experiment has been performed and reports no measured result.

![Native research workspace showing a demonstration result record and understanding snapshot](images/macos-research-results.jpg)

## Compare papers with sources attached

Cross-paper comparison keeps findings tied to exact quotations from the selected papers. Analysis and comparison use an optional OpenAI-compatible provider; the pictured comparison uses a local synthetic response to demonstrate the interface and citation validation.

![Native cross-paper comparison with source quotations beneath each finding](images/macos-comparison.jpg)

## See what the server is doing

The task view lists durable operations and exposes their progress and stages. This capture shows completed PDF imports, three paper analyses, a comparison, and a figure repair from the demonstration workspace. The selected import shows parsing completed for both pages.

![Native task view with completed imports, analyses, comparison, and figure repair](images/macos-tasks.jpg)

## Light and dark appearance

The library and PDF reader also support dark appearance. These captures come from the earlier sample workspace used for the web gallery.

![Native Mac library in dark appearance](images/macos-library.jpg)

![Native Mac PDF reader and page-linked note in dark appearance](images/macos-reader.jpg)

## About these captures

The screenshots were taken directly from an isolated preview build of the existing app, connected to a disposable local API and database. Fifteen new captures extend the two dark-appearance Mac images from the [original gallery](SCREENSHOTS.md). The preview identity used temporary credentials and did not access the installed app's saved connection.

The new workspace contains six synthetic PDFs, three candidates, three groups, and one research question. Imports, parsing, figure repair, and evidence saving used the actual application and worker paths. The analysis and comparison text was hand-authored demonstration content served by a deterministic local provider, then processed by the real model gateway, response-schema checks, and exact-quotation validation. No paid or remote model calls were made. These examples illustrate interface behavior, not model quality or scientific results.

No personal papers, credentials, or production deployment details appear in the images. The original source PDFs and temporary workspace are not distributed. See [feature boundaries](FEATURES.md) and [verification notes](VERIFICATION.md) for the current limits.
