# Reading Log for SimpleUI

Runs [Reading Log](https://github.com/stevenzamora1/reading-log) (by stevenzamora1, AGPL-3.0) as SimpleUI home screen modules. No Bookshelf needed.

## Install
1. Copy `simpleui_readinglog.koplugin` into `koreader/plugins/` (next to `simpleui.koplugin`).
2. Restart KOReader.

## Screenshots

![Today](images/readinglog-today.png)
![Monthly](images/readinglog-monthly.png)
![Yearly](images/readinglog-yearly.png)
![Settings](images/readinglog-settings.png)

## Put the dashboard on page 2
1. Simple UI → Home Screen → Modules: set **Number of Pages** to 2.
2. Tick **Reading Log · Dashboard**.
3. **Arrange Modules**: move the Dashboard to page 2, alone.
4. If it overflows or leaves a gap: Module Settings → Reading Log · Dashboard → **Height (% of screen)**.

Dashboard tabs (Today / Monthly / Yearly) and the month arrows work by tap. Swipe still turns SimpleUI pages.
Pages, cards, theme and accents: Module Settings → Reading Log · Dashboard → **Reading Log Settings…**
Size, height, night theme, ghosting flash: Module Settings → Reading Log · Dashboard → **Appearance**

Every single card is also available as its own module (`Reading Log · Activity Rings`, etc.).

## Notes
- Settings are stored in `koreader/settings/simpleui_readinglog.lua`, separate from Bookshelf.
- Night mode: cards switch to the Dark theme while night mode is on. Change it in Module Settings → any Reading Log module → Night Mode Theme.
- The banner clock updates when the home screen redraws, not every minute.
- "Details" on a book opens SimpleUI's own book menu (mark finished / on hold, collections, book info...).
- Tabs, month arrows and data updates redraw only the dashboard, not the whole home page. The hidden tabs are pre-loaded a few seconds after the dashboard first shows.
- Size (Appearance) scales all text: small labels fully, big numbers and titles at half strength. Rings, charts and covers follow the card's size, so use Height for those.
- Added card: **Year Goal With Covers** (books finished vs your goal, with this year's covers). It replaces Book Club on the Today tab unless you've edited that page yourself.
- Year Goal and daily minutes come from SimpleUI's Reading Goals (Simple UI → Stats). Changing the goal in either place changes both.
- Module Settings → any Reading Log module → **Reading Goals**: books this year, read outside KOReader, minutes a day, pages a day. Books and minutes are SimpleUI's own Annual/Daily goals.
- Module Settings → Reading Log · Dashboard → Appearance → **Layout**: *In the page* (default) or *Full screen* (fills everything between the status bar and nav bar).
- Opening a book or sleeping sends the home screen back to page 1 (Dashboard module settings → "Start On First Page After Reading Or Sleep").
- Dashboard module settings → **Today Page Card**: Year Goal With Covers (default), Year Goal, Book Club, Recently Finished or TBR Shelf.
- Finish dates: a finished book reopened briefly (and re-marked finished by KOReader) keeps its real finish date — the last day with real reading (1 min or 2 pages). Longest reads, months and covers all use it.

## Credits
The Reading Log kit (`readinglog/almanac/`) is ported from [Reading Log](https://github.com/stevenzamora1/reading-log) by stevenzamora1 (AGPL-3.0) — thank you! The SimpleUI integration (`main.lua`) is new work by TK, also AGPL-3.0. Full license text: `LICENSE`.
