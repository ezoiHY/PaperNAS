# Paper NAS · Native macOS

A quiet research library, built with SwiftUI and PDFKit. The server owns all durable research data.

## Direction
Native macOS navigation split view, system toolbar, resizable columns, standard window controls, system settings. Icon-first actions with tooltips, VoiceOver labels and keyboard equivalents. SF Symbols throughout. Chinese interface and genuine English paper titles. No decorative metrics, gradients, invented content or marketing panels.

Use system fonts and semantic NSColor/SwiftUI colors. Native accent blue; status dots blue for deep reading, green for brief reading, amber for attention, each with an accessible textual explanation. Follow system appearance and increased contrast/reduced motion. Materials belong in navigation chrome; reading surface remains quiet and opaque.

## Library
Sidebar 190–250 pt. Library/candidates/tasks at top, real groups below, connection/settings at bottom. The library fills the canvas. A primary click opens the exact paper in an immersive reader, hiding both the paper list and navigation sidebar until the user returns. List and figure grid views. Show real thumbnail, date/source, title, first author plus available affiliation, one-sentence recall, real groups. Omit missing affiliation/group labels. Keep title and summary readable; actions in toolbar/context menus.

## Reader
PDFKit for original PDF; native SwiftUI sections, rich text, dataset fields, references and figures for analysis. Treat reports as an edited reading experience: a centered, fully wrapping paper masthead; a quiet summary panel; centered numbered chapter headings; and left-aligned prose with hanging item numbers. Brief reading retains its material coverage and deep reading retains every structured finding. A collapsible 192 pt outline tracks the current chapter. Below 720 pt, a persistent footer provides chapter navigation without covering the text. The paper list and library sidebar remain hidden during reading.

Default body text is 17 pt with a local serif/CJK Songti font cascade, an 820 pt prose measure and comfortable line spacing. The native appearance popover offers book/modern type, 15–21 pt sizes, three line-height settings and three measures. These preferences persist locally and also apply to math. Figure plates may expand to 1000 pt; captions return to the prose measure with a hanging figure label. Dataset cards preserve field order and stack labels above values when space is limited. Focus mode hides both outline and notes, then restores their previous state when exited. The footer provides progress, previous/next chapter and a contents menu.

Candidate rows and cards show the saved interest relevance score from enrichment.score in a compact labeled badge, with the original reason as a tooltip. Missing scores have an explicit unscored label. Search ranking scores are separate.

Load inline figures through the authenticated server asset API using the report's actual figure identifiers. Preserve aspect ratio, reserve loading space and retain captions. Clicking opens a native original-image sheet with fit, zoom and actual-size actions. Citation controls open compact source excerpts; dataset details retain their original field order. Keep checks and full evidence accessible, and put provenance/technical metadata behind the info icon. Do not insert raw model JSON or Markdown metadata into the body. Only math paragraphs need a local KaTeX typesetting view; all surrounding layout and controls are native.

Native segmented icon control: report, PDF, source text, figures. The reader occupies the whole window; an icon in the window toolbar returns to the library. Optional right pane for notes. Reading position lives on server; per-window layout is local. Notes have PDF fingerprint, page and explicitly versioned coordinate anchors. No fabricated original documents or invented figure-to-claim associations.

Reading references: Apple Books typography controls and Readwise Reader's appearance controls informed the adjustable measure, spacing and type. Their interface was not copied. Keep the reading surface opaque, preserve original figure colors, and use semantic foreground colors in both light and dark appearances.

## Interaction
Rows and cards are full-width buttons with visible hover, press, focus and selection feedback. Plain click opens reading; Command-click toggles batch selection and Shift-click selects a range. Up/Down changes the selected paper and Return opens it. One navigation state owns selection and the open paper. Command-[ returns to the retained library selection; Command-F returns to library search. Buttons have accessible labels even when only icons are drawn. Main actions: add, search, filter, layout, refresh, analyze, inspector. Standard context menu exposes less frequent actions. Loading and disconnected states keep last valid visible data. Destructive actions use explicit confirmation. Failed saves retain drafts and surface conflict details.

## Source fit
ui-ux-pro-max design-system searches returned Minimalism & Swiss style suitable for restrained content presentation, but landing-page patterns and web fonts did not fit a native Mac app and were rejected. Native layout uses platform guidance and the skill’s general accessibility defaults. SwiftUI-specific guidance validated semantic controls, type-safe navigation and labels.
