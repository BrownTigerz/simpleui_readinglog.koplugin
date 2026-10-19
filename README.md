# Reading Log for SimpleUI

Runs [Reading Log](https://github.com/stevenzamora1/reading-log) (by stevenzamora1, AGPL-3.0) as SimpleUI home screen modules. No Bookshelf needed.

## Requirements
- KOReader with [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) installed and enabled.
- KOReader's **Reading statistics** plugin switched on (it is by default). Every number on the dashboard comes from it.
- A colour screen is optional. On black-and-white screens the colours show as greys.

## Install
1. Download `simpleui_readinglog.koplugin.zip` from [Releases](../../releases) and unzip it.
   Don't use GitHub's green **Code → Download ZIP**: that folder has the wrong name and won't load.
2. Copy the `simpleui_readinglog.koplugin` folder into `koreader/plugins/` (next to `simpleui.koplugin`).
3. Restart KOReader.

## Updating
1. Delete the old `simpleui_readinglog.koplugin` folder from `koreader/plugins/`.
2. Copy the new one in and restart KOReader.

Copying over the old folder can leave the old version running. Your settings are kept either way, because they live in `koreader/settings/simpleui_readinglog.lua`.

## Screenshots

![Today](images/readinglog-today.png)
![Monthly](images/readinglog-monthly.png)
![Yearly](images/readinglog-yearly.png)
![Settings](images/readinglog-settings.png)

## Put the dashboard on page 2
1. Simple UI → Home Screen → Modules: set **Number of Pages** to 2.
2. Tick **Reading Log · Dashboard**.
3. **Arrange Modules**: move the Dashboard to page 2, alone.
4. If it overflows or leaves a gap: Module Settings → Reading Log · Dashboard → **Appearance → Height (% Of Screen)**.

The Today / Monthly / Yearly tabs and the month arrows work by tap. Swipe still turns SimpleUI pages.

Every card is also available as its own module (`Reading Log · Activity Rings`, etc.).

## Settings
All of these are in Module Settings → Reading Log · Dashboard.

| Setting | What it does |
| --- | --- |
| **Reading Goals** | Books this year, read outside KOReader, minutes a day, pages a day. Books and minutes are SimpleUI's own Annual and Daily goals (Simple UI → Stats), so changing them in either place changes both. |
| **Today Page Card** | The card under the rings on the Today tab: Year Goal With Covers (default), Year Goal, Book Club, Recently Finished or TBR Shelf. |
| **Reading Log Settings…** | Pages and cards, theme, accent colours, and each card's own options. |
| **Appearance → Layout** | **In The Page** (default) sits in SimpleUI's page like any module. **Full Screen** fills everything between the status bar and the nav bar, so every card is bigger. |
| **Appearance → Size** | Scales the text. Small labels scale fully, big numbers and titles at half strength. Rings, charts and covers follow the card's size, so use Height for those. |
| **Appearance → Height (% Of Screen)** | How much of the page the dashboard fills. |
| **Appearance → Night Mode Theme** | The theme used while night mode is on: Dark (default), Paper, White or Same As Day. |
| **Appearance → Flash To Clear Ghosting** | Flashes the screen when you switch tabs or turn onto or off the dashboard page, so the old page doesn't linger. Turn it off for faster tab switches at the cost of some ghosting. |
| **Start On First Page After Reading Or Sleep** | Opening a book or putting the device to sleep sends the home screen back to page 1. |

## Notes
- **Book Details:** "Details" on a book opens SimpleUI's own book menu (mark finished or on hold, collections, book info…).
- **Finish dates:** reopening a finished book for a moment can make KOReader mark it finished again with today's date. Reading Log ignores that and uses the last day of real reading (at least 1 minute or 2 pages), so Longest Reads, the monthly lists and Year In Covers stay correct. If Bookshelf is also installed, its own Reading goals card still uses KOReader's date and may count that book in the wrong month.
- **Redrawing:** tabs, month arrows and data updates redraw only the dashboard, not the whole home page. The hidden tabs are pre-loaded a few seconds after the dashboard first shows.
- **Clock:** the banner clock updates when the home screen redraws, not every minute.

## Credits
The Reading Log kit (`readinglog/almanac/`) is ported from [Reading Log](https://github.com/stevenzamora1/reading-log) by stevenzamora1 (AGPL-3.0). Thank you! The SimpleUI integration (`main.lua`) is new work by TK, also AGPL-3.0. Full license text: `LICENSE`.
