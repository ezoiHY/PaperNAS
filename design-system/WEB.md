# Paper NAS web interface

The accepted “Focus library” prototype is the visual reference. The web client is a working research tool, with the same durable data as the Mac app.

- Background `#ffffff`, navigation `#f5f6f8`, text `#24272e`, secondary text `#646b76`, rule `#e9ebef`, accent `#4165ba`. Dark appearance uses semantic equivalents.
- System sans-serif for navigation and lists; local Georgia/Songti serif for sustained reading. No downloaded fonts.
- A 208px sidebar, a quiet toolbar, full-width paper rows, and an 820px reading measure. Left-aligned content. Figures keep their original colors.
- Small 6–8px control radii, fine separators, blue selection. Shadows belong to dialogs; the working canvas stays flat.
- Desktop navigation collapses into a labeled menu on mobile. Keyboard focus stays visible; all dialogs, fields and icon controls have accessible names.
- Empty/error states explain the next action. Missing metadata is omitted. No invented papers, counts, figures or reports in the live product.

The ui-ux-pro-max search confirmed Flat Design guidance for a productivity workspace. Its landing-page layout, teal palette and external font suggestions do not fit this accepted reference; the user's existing design determines those choices.

```text
Sidebar           Toolbar / actions
Library           Search and filters
Candidates        Title of a paper                  Group
Research          Author, publication date
Tasks             ─────────────────────────────────────
Groups            Next paper
Settings
```

Opening a paper gives the full main area to reading. Tabs switch between analysis, PDF, extracted text, figures and notes. Research records use sections and readable lists, with editing actions exposed where needed.
