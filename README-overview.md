# CLI-Browser

A friendly, capable, full-featured command-line browser for PowerShell.

Real Chromium under the hood. Colored, numbered, and designed to feel easy — even on complex sites like CNN or NYTimes, or locked-down firewall UIs.

## Features

- **Reader mode** — clean article text
- **Bookmarks** — saved to your profile, use `bm` and `goto bm:name`
- **Multi-tab** — `newtab`, `tabs`, `tab 2`
- **Cookie auto-accept** — tries common consent buttons (disable with `-NoAutoConsent`)
- **Custom user-agent** — `-UserAgent "..."`
- **Numbered everything** — links, elements, tabs
- **Rich color UX** — clear prompts, sections, status
- **Screenshots & PDF**
- **Auto-install** Pup + Chromium

## Quick Start

```powershell
.\CLI-Browser.ps1
.\CLI-Browser.ps1 -StartUrl "https://www.cnn.com"
.\CLI-Browser.ps1 -StartUrl "https://www.nytimes.com" -Visible
.\CLI-Browser.ps1 -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
```

## Friendly Commands

```
goto cnn.com
reader                  # clean reading
links                   # numbered links
follow 3
bm add cnn              # bookmark current page
goto bm:cnn
newtab nytimes.com
tabs
tab 1
scan
click 2
type 1 admin
screenshot
pdf
help
quit
```

Prompt shows current tab and host: `[1] www.cnn.com>`

## Requirements

Windows + PowerShell 5.1+. First run installs dependencies automatically.

MIT (this wrapper). Pup is MIT. Chromium is BSD.
