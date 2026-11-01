# SlyKiss HoTMetaL: Architectural Whitepaper and Technical Reference

“SlyKiss HoTMetaL: Text-Mode Chromium Automation for Network Engineers.”

**Author:** Jim Ames, N2NHU Labs (Newburgh, NY, USA)  
**Collaborators:** Claude, Grok, DeepSeek, and Google Gemini  
**Product Version:** 6.2  

---

demo video

https://youtu.be/_rFV6H_ylgo?si=TnXaNOq2C2Lwp8ET


## Abstract

Modern IT infrastructure management is defined by a widening architectural paradox: while administrative interfaces for enterprise firewalls, hypervisors, and cloud infrastructure have migrated exclusively to rich, JavaScript-heavy web applications, systems administration has simultaneously shifted toward headless, automated, and text-only execution environments—such as Datto RMM PowerShell component jobs. 

Traditional text-mode browsers (e.g., Lynx, w3m) fail against modern Single Page Applications (SPAs) and dynamic Document Object Models (DOMs), while heavyweight browser automation tools (Selenium, Playwright, Node-based Puppeteer) introduce massive dependency trees unsuited for unattended remote endpoints. 

This whitepaper details **SlyKiss HoTMetaL (CLI-Browser)**, a text-mode Chromium engine built on the Chrome DevTools Protocol (CDP) via PowerShell. HoTMetaL resolves this friction by operating as a deterministic algebraic state machine, offering an efficient bridge for headless RMM automation, administrative web console management, and interactive terminal browsing.

---

## 1. Etymology and Design Philosophy

The name **SlyKiss HoTMetaL** stems from a deliberate typographic portmanteau representing its foundational layers:
* **CLI** (Sly)
* **CSS** (Kiss)
* **HTML** (HoTMetaL)

Beyond its nomenclature, the project draws conceptual inspiration from the historic **Linotype machine**, which revolutionized publishing by casting molten metal slugs line-by-line into structured galleys. Similarly, HoTMetaL takes the chaotic, dynamic stream of modern Chromium DOM nodes and compiles them into a clean, sequential, numbered text inventory.

### Core Architectural Laws
HoTMetaL enforces strict operational invariants:
1. **Single Namespace:** Every interactive element (links, buttons, inputs, checkboxes, table rows) maps to a single, unified integer index within the active page snapshot.
2. **Handle Verification:** Actions verify both attachment and structural fingerprints (`kind|tag|label|name`) prior to execution, preventing race conditions or stale element interaction.
3. **Dialogs as Data:** Native dialogs (`alert`, `confirm`, `prompt`) do not block execution threads. Confirmations default to `CANCEL` unless explicitly overridden with a command-line bang (`!`).
4. **Idempotent Mutations:** Form filling and state changes are strictly idempotent.
5. **Zero Unsolicited Automation:** Cookie banners and modal overlays remain untouched unless explicitly targeted via the `consent` command.

---

## 2. Comparative Analysis: HoTMetaL vs. Browsh vs. Legacy Tools

To contextualize HoTMetaL's position in the ecosystem, it is valuable to examine how it compares against alternative terminal browsing strategies, specifically **Browsh** and traditional text-mode utilities.

### Architectural Comparison Matrix

| Feature | SlyKiss HoTMetaL (`CLI-Browser`) | Browsh (`brow.sh`) | Traditional Text Browsers (`Lynx` / `w3m`) | Headless Selenium / Node Puppeteer |
| :--- | :--- | :--- | :--- | :--- |
| **Underlying Engine** | Chromium / CDP (`Pup` module) | Headless Firefox + Web Extension | None (Parser-based) | Webdriver / Node.js Runtime |
| **Execution Paradigm** | Deterministic Text State Machine | Pixel-mapped UTF-8 Terminal Graphics | Static HTML Rendering | Programmatic Code API |
| **RMM & PowerShell Ready** | **Native** (PowerShell / Headless) | **Poor** (Requires local binary/Firefox) | **Poor** (External shell utilities) | **Poor** (Requires Node.js / heavy runtimes) |
| **Firewall / Grid Handling** | **Specialized** (Resolves `jqGrid`, frames) | **General** (Renders visual layout) | **Broken** (Fails on modern JS SPAs) | **Custom Code Required** |
| **Human-in-the-Loop** | Seamless `human` window handover | Interactive only | Interactive only | Requires complex remote debugging |

### Why Browsh Differs
While **Browsh** provides an impressive visual terminal experience by launching headless Firefox and mapping pages into UTF-8 half-block characters (`▄`), it is fundamentally a graphical proxy designed for human browsing. It demands significant system resources, relies on local Firefox binaries, and lacks a native, scriptable command DSL. HoTMetaL, conversely, abstracts the browser into raw structured data, prioritizing programmatic control, minimal overhead, and script execution.

---

## 3. Operational Environment: The Datto RMM Shift

The operational necessity for HoTMetaL has been heavily amplified by modern endpoint management trends. With the transition to platforms like **Datto RMM**, systems administrators frequently operate without an interactive desktop session on target servers or managed appliances. 

Under these constraints:
* `Invoke-WebRequest` and standard REST wrappers fail when appliances require complex session tokens, multi-step cookie handshakes, or dynamic form rendering.
* Full UI test frameworks require heavy runtimes that violate lightweight RMM component design standards.

HoTMetaL integrates natively into PowerShell component jobs, allowing automation scripts to log into firewall consoles, modify interface states, parse monitoring tables, and extract audit data without user intervention.

---

## 4. Technical Specifications and Implementation

### The Single-File Kernel
HoTMetaL encapsulates its core page-interaction logic in a strict, ASCII-only JavaScript kernel (`$script:KERNEL`). This kernel executes directly within the browser context via CDP, handling:
* **Shadow DOM & Frame Traversal:** Recursively walks shadow roots and same-origin frames while filtering out advertising networks and tracking frames (`ADRX`).
* **Grid and Table Parsing:** Identifies genuine data rows (such as `jqGrid` implementations) and associates them with column headers and container titles.
* **Network & Mutation Observers:** Tracks asynchronous XHR/Fetch requests and DOM mutations to determine true page quiescence (`settle`).

### Command-Line DSL & Scripting
The browser operates via a pure parser mapping lines to commands (`parse : Line -> [Cmd]`), evaluated sequentially (`a ; b`). 

```powershell
# Example Datto RMM Component Execution String
.\CLI-Browser.ps1 fw01.corp.local:8443 -Exec '"Username"=admin; "Password"=env:FWPASS; "Login"; expect Dashboard; text' -Dump
```

* **Interactive Lynx-Style Mode:** Launching without parameters starts an intuitive terminal interface featuring arrow-key navigation, folded site menus (`m`), regex searching (`/`), and article reader mode (`r`).
* **Challenge Handling:** When encountering bot-mitigation checkpoints (Cloudflare, reCAPTCHA), the `human` command temporarily spins up a visible window for manual verification, extracts the resulting session tokens, and seamlessly resumes headless text-mode execution.

---

## 5. Conclusion

SlyKiss HoTMetaL successfully bridges the gap between the modern, web-centric GUI demands of network appliances and the austere, headless realities of modern PowerShell RMM automation. By treating the browser as a state-machine data structure rather than a graphical viewport, it delivers robust, scriptable, and secure web administration from the command line.
