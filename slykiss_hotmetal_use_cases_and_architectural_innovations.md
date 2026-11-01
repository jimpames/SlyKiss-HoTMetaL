# SlyKiss HoTMetaL: Problems Solved, Use Cases, and Architectural Innovations

**Author:** Jim Ames, N2NHU Labs (Newburgh, NY, USA)  
**Collaborators:** Claude, Grok, DeepSeek, and Google Gemini  
**Product Version:** 6.2  
**Companion paper:** *SlyKiss HoTMetaL: Architectural and Code-Level Whitepaper*

---

## Abstract

Two previous papers described *how* SlyKiss HoTMetaL (CLI-Browser) is built—its kernel design, its algebraic state machine, its pure/effect split, and its test harness. This paper is about *why it exists* and *where it is useful*. It is written for engineers evaluating the tool, not for engineers maintaining it.

The core argument is that a specific class of automation problem—**driving a JavaScript-heavy web console from a headless, non-graphical, PowerShell-native environment**—is systematically underserved by the available tooling. 

`Invoke-WebRequest` cannot execute JavaScript. Selenium and Playwright require runtimes (Node, Python, .NET) that violate the design constraints of endpoint agents and RMM components. Lynx and w3m predate SPAs. Browsh renders pixels to a terminal but exposes no scripting surface. Nothing in the existing landscape gives you a PowerShell script that can log into a FortiGate web UI, click a `jqGrid` row, dismiss a Bootstrap modal, and extract a policy table—all from a component job on a managed endpoint with no desktop session.

HoTMetaL occupies that gap. This paper describes the gap in detail, enumerates the use cases it enables, and then separates the genuinely novel contributions from the standard engineering. It is deliberately honest about what the tool does not do.

---

## Table of Contents

1. [The Problem Space](#1-the-problem-space)
2. [Why Existing Tools Fall Short](#2-why-existing-tools-fall-short)
3. [Use Cases](#3-use-cases)
4. [Architectural Innovations](#4-architectural-innovations)
5. [What Is Not Novel](#5-what-is-not-novel)
6. [Limitations](#6-limitations)
7. [Comparison to the Alternatives, Revisited](#7-comparison-to-the-alternatives-revisited)
8. [Conclusion](#8-conclusion)
- [Appendix A: A Complete Working Example](#appendix-a-a-complete-working-example)
- [Appendix B: The Command Grammar](#appendix-b-the-command-grammar)

---

## 1. The Problem Space

Four distinct problems motivate HoTMetaL. They overlap in practice but are worth separating analytically.

### 1.1. The RMM Execution Context

A modern endpoint management platform—Datto RMM, NinjaOne, ConnectWise Automate, Kaseya VSA—runs automation on managed endpoints in a context that looks nothing like a developer workstation:

- **No interactive desktop session.** Scripts execute under the SYSTEM account or a service account in session 0. There is no `Session 1` to render windows into, no display server, no user profile with a browser cache.
- **PowerShell is the native scripting surface.** RMM component jobs are PowerShell (or batch) with a defined exit-code contract. Python, Node, and Go are optional and often absent. Every extra runtime is an install and maintenance burden.
- **No persistent state between jobs.** Each component job runs in a fresh process. Long-lived browser sessions, saved cookies, and cached credentials do not carry over unless you serialize them explicitly.
- **Execution time budgets.** Datto RMM component jobs default to 3600 seconds. Some environments configure shorter limits. Anything that takes minutes to boot is dead on arrival.
- **Locked-down endpoints.** Application allow-listing, AppLocker, Windows Defender Application Control, and network egress filtering are common. A tool that downloads a 150 MB Node bundle on first run may simply fail.
- **Audit expectations.** Every command executed against a managed firewall must be loggable, reviewable, and attributable. A tool whose default behavior includes "auto-click the cookie banner" and "retry on failure" is a compliance risk.

HoTMetaL is designed against these constraints. It assumes PowerShell 5.1 on Windows, the `Pup` module, a headless Chromium instance, and nothing else. It uses the user profile directory (`~/.cli-browser/`) for bookmarks, downloads, and logs, which is available even under a service account. It logs every command and every Chrome interaction to a rolling 2 MB file so that any incident can be reconstructed.

### 1.2. The Firewall Console Problem

Network appliances are the canonical case. A FortiGate web UI, a SonicWall NSA management console, a WatchGuard Firebox, a Palo Alto PAN-OS GUI, an F5 BIG-IP—all of them have *some* REST API, but the practical reality is:

- **The API is incomplete.** Every vendor has features that exist only in the GUI. Fortinet's `CMDB` API is powerful but documented unevenly; WatchGuard's Fireware Web UI exposes policy editing that has no documented REST equivalent. WatchGuard in particular is where "only in the GUI" is the norm, not the exception.
- **The API is versioned differently from the GUI.** REST endpoints are added and deprecated on their own schedule. A script that worked against firmware 7.0 breaks against 7.4.
- **The GUI enforces business logic the API doesn't.** Confirmation dialogs, role checks, session tokens, and CSRF protections are enforced at the web layer, and the API sometimes skips them in ways that are hard to model.
- **The GUI runs on non-standard ports.** FortiGate on 4443 or 8443. SonicWall on 4433. WatchGuard on 8080. These are administrative ports, often reachable only from a management VLAN, and often presenting self-signed certificates.
- **The GUI is JavaScript-heavy.** FortiGate's console uses jQuery, Bootstrap, and `jqGrid`. WatchGuard's Fireware Web UI is a Bootstrap 2.x application with a nested frame structure. These are not "modern SPAs" in the React sense, but they are 100% dependent on client-side JavaScript execution. `Invoke-WebRequest` returns an HTML shell with no data.

The consequence: a substantial fraction of administrative operations on enterprise firewalls cannot be scripted using any of the standard mechanisms. The choice is between a human at a browser, or a browser automation framework that is too heavy to deploy.

### 1.3. The Headless Browser Automation Gap

The available browser automation tools fall into three categories, and each fails a different constraint:

**Category A: WebDriver-based frameworks (Selenium, Playwright, Puppeteer via Node).**  
These work. They render JavaScript, they can interact with DOM elements, they expose a scripting API. But they require a runtime (Java, Python, Node.js, or .NET SDK), they require the WebDriver binary or a browser bundle (Chromium downloads are 100-150 MB), and they require ongoing version management. On a Windows Server 2016 endpoint with Defender ASR rules enabled and no internet access, "just install Playwright" is not a sentence that survives the first change-control meeting.

**Category B: HTTP-only tools (`Invoke-WebRequest`, `curl`, `requests`).**  
These are lightweight, available everywhere, and useless against SPAs. They can scrape static HTML, and they can hit REST endpoints if you already know the session token flow—but reconstructing a FortiGate session from `curl` commands is a research project, not an automation primitive.

**Category C: Text-mode browsers (Lynx, w3m, Links).**  
These are excellent at static content and completely blind to JavaScript. They do not execute client-side code, they do not traverse shadow DOM, and they cannot interact with a `jqGrid`. Browsh addresses the JavaScript gap by rendering headless Firefox to UTF-8 half-blocks, but it does so for *human* consumption—there is no scripting DSL, no item numbering, no headless mode with structured output. It is a browser, not an automation tool.

None of the three categories produces something you can hand to a junior network engineer as "here's a PowerShell script that patches our FortiGate SSL VPN certificate every 90 days." HoTMetaL is designed to fill that specific gap.

### 1.4. The AI-Agent Collaboration Problem

A newer problem, and one worth naming: as autonomous agents become capable of driving browsers, they need tools whose effects are *enumerable*, *inspectable*, and *reversible-or-refusable*. A tool that auto-clicks on heuristics is a liability when the agent is LLM-driven; the agent needs to know what it did, what it could have done, and what it refused to do.

HoTMetaL's design constraints—numbered namespace, fingerprint verification, dialogs defaulting to CANCEL, zero auto-clicking—are directly aligned with this. The state snapshot (`snap`) is a clean, JSON-serializable representation of the page that an agent can inspect before acting. The command grammar (`12!`, `"Login"=admin`, `4=env:FWPASS`) is unambiguous and easy to emit from an LLM. The `expect <text>` command is a structured assertion the agent can use to verify each step.

This is not the primary use case, but it is a design property worth calling out: HoTMetaL is a browser automation tool that a machine can safely drive, not just a tool a human can conveniently use.

---

## 2. Why Existing Tools Fall Short

A comparative table clarifies the positioning:

| Constraint | Selenium / Playwright | Invoke-WebRequest | Lynx / w3m | Browsh | HoTMetaL |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Executes JavaScript** | ✓ | ✗ | ✗ | ✓ | ✓ |
| **Available as a PowerShell module** | ✗ (needs runtime) | ✓ (built in) | ✗ (external binary) | ✗ (needs Firefox) | ✓ |
| **Runs under a service account without a desktop** | ✓ (with config) | ✓ | ✓ | ✗ (needs display) | ✓ |
| **Headless structured output** | Partial | ✓ | Partial | ✗ | ✓ (`-Dump`) |
| **Scriptable command grammar** | ✓ (code API) | ✓ (HTTP) | ✗ | ✗ | ✓ |
| **Handles dialogs as data** | Requires code | N/A | N/A | Human-only | ✓ |
| **Traverses shadow DOM and iframes** | ✓ | ✗ | ✗ | ✓ | ✓ |
| **Detects `jqGrid` rows and headers** | Requires code | ✗ | ✗ | ✗ | ✓ |
| **Human-in-the-loop handover** | Requires code | N/A | N/A | N/A | ✓ (`human`) |
| **Install footprint** | 100-500 MB | 0 MB | 5-20 MB | 80-200 MB | ~150 MB (Chromium only) |
| **Default-safe (no auto-clicking)** | ✗ (framework-dependent) | N/A | N/A | N/A | ✓ |
| **Audit log of every action** | Requires setup | Requires setup | ✗ | ✗ | ✓ (automatic) |

The interesting cells are the ones where HoTMetaL is uniquely good:
- **Headless structured output combined with a scriptable grammar.** Selenium can do both, but requires you to write and maintain the script. HoTMetaL is the script—the DSL is the tool.
- **Available as a PowerShell module.** No runtime installation, no version management, no dependency tree beyond Chromium.
- **Handles dialogs as data.** This is genuinely rare. Most tools either block on dialogs or auto-accept them. HoTMetaL queues them and defaults to CANCEL.
- **Detects `jqGrid` rows and headers.** This is firewall-specific but it is the single most important capability for the target user. FortiGate, WatchGuard, and SonicWall all use `jqGrid` or a close relative.

The cells where HoTMetaL is weak or equivalent:
- **Install footprint.** Chromium is 150 MB. This is smaller than Playwright + Node + browser, but it is not zero. On endpoints with strict allow-lists, this is a problem.
- **Speed.** Headless Chromium startup is 2–4 seconds. `Invoke-WebRequest` is instant. For a script that needs one HTTP call, HoTMetaL is overkill.

The tool is not a replacement for `Invoke-WebRequest` when `Invoke-WebRequest` works. It is a replacement for "we can't automate this at all" and for "we're paying a human to click through the same dialog every Tuesday."

---

## 3. Use Cases

The following are concrete scenarios where HoTMetaL provides capabilities that nothing else in the PowerShell-native ecosystem does. Each is written with enough detail to be adapted.

### 3.1. Automated Firewall Certificate Renewal (Datto RMM)

**Problem.** A managed service provider (MSP) manages 40 FortiGate firewalls across 40 customer sites. Each firewall has an SSL VPN certificate that must be renewed every 90 days. The FortiGate REST API *can* import certificates, but the workflow also requires:
1. Logging into the web UI (the API session token works, but the SSL VPN portal needs a separate UI-configured binding).
2. Navigating to System → Certificates → Local Certificates.
3. Verifying the certificate chain is present and the expiry date is later than the current date.
4. Uploading the new certificate and key.
5. Navigating to VPN → SSL-VPN Settings and re-binding the certificate to the portal.
6. Verifying the SSL VPN portal shows the new certificate.

Step 5 has no API equivalent on firmware 7.0. Step 3 is a *verification* step that must fail loudly if the certificate chain is wrong. Step 6 is a *verification* step that must fail loudly if the binding did not take effect.

**Solution.** A PowerShell component job distributed through Datto RMM:

```powershell
$fw = Get-DeviceUri  # from RMM context
$certPfx = Join-Path $env:TEMP "vpn-cert-$((Get-Date).ToString('yyyyMM')).pfx"
Invoke-WebRequest -Uri $certUrl -OutFile $certPfx  # from internal PKI
$pw = Get-RmmSecret "fw-cert-pass"

$script = @'
"Username"=admin
"Password"=env:FWPASS
"Login"
expect Dashboard
"System"
"Certificates"
"Local Certificates"
expect "vpn.example.com"
text
"Import"
"Certificate File"=$certPfx
"Password"=$pw
"OK"
expect "vpn.example.com"
"SSL-VPN Settings"
expect "vpn.example.com"
"Certificate"=vpn.example.com
"Apply"
"OK"
expect "vpn.example.com"
"Logout"
'@

.\CLI-Browser.ps1 "https://$fw`:4443" `
    -Run "import-cert.cli" `
    -Exec "$script" `
    -Dump `
    -TimeoutSec 90

if ($LASTEXITCODE -ne 0) { exit 1 }
```

**Why this works where nothing else does.** The `expect "vpn.example.com"` after the certificate upload is a semantic verification: it proves the certificate appeared in the list before the script proceeds to the VPN binding step. The `-Dump` output is a plain-text rendering of the final page, which the RMM job can parse for the `expires=` field to log the new expiry date. Every step is logged with the actual item number and the actual label, so if the FortiGate firmware updates and changes the menu text, the log immediately shows `Nothing labelled "Local Certificates" on this page` rather than failing silently.

### 3.2. Configuration Drift Detection (Scheduled Audit)

**Problem.** A security team wants a weekly snapshot of every firewall's outbound policy table, to detect unauthorized changes. The FortiGate API can enumerate policies, but the API's returned JSON does not include the GUI-specific computed fields (e.g., resolved address objects, shadowed policy warnings) that the web UI displays. Those are computed server-side and rendered only for the human operator.

**Solution.** A weekly PowerShell job that logs in, navigates to Policy & Objects → IPv4 Policy, and captures the rendered grid as text:

```powershell
.\CLI-Browser.ps1 "https://$fw`:4443" `
    -Exec '"Username"=admin; "Password"=env:FWPASS; "Login"; expect Dashboard; "Policy & Objects"; "IPv4 Policy"; expect "Outbound"; text' `
    -Dump `
    -TimeoutSec 120 | Set-Content "policy-snapshot-$((Get-Date).ToString('yyyy-MM-dd')).txt"
```

The `-Dump` output is the rendered table, including the computed columns. Diffing this against the previous week's snapshot catches changes that the API would miss.

**Why this works.** `Format-CliText` aligns tab-separated cell runs into columns, so the dumped text is stable across weeks even if the browser window changes size. The `expect "Outbound"` guard means the script fails cleanly if the firewall is down or the login fails, rather than writing an empty file that the diff tool then interprets as "all policies removed."

### 3.3. Shadow DOM Web Console Management (Third-Party SaaS)

**Problem.** A SaaS vendor's admin console uses a modern web component architecture with shadow DOM boundaries. The console has no documented API. Administrative tasks—user provisioning, role assignment—must be done through the UI.

**Solution.** HoTMetaL traverses open shadow roots through the kernel's nodes iterator:

```powershell
.\CLI-Browser.ps1 "https://admin.saas-vendor.com" `
    -Exec '"Email"=env:SAAS_EMAIL; "Password"=env:SAAS_PASS; "Sign In"; expect Dashboard; ls in; ls btn; text' `
    -Dump
```

The `ls in` command enumerates every input field—including those inside shadow DOM—and `ls btn` enumerates every button. The user can then scan the actual items and build a targeted action sequence.

**Why this works.** The kernel's `nodes()` function recursively descends into `element.shadowRoot` for any element that has one. This is a capability that `Invoke-WebRequest` fundamentally cannot provide, and that Lynx/w3m/Browsh do not expose. Playwright does support shadow DOM, but requires the Playwright runtime.

### 3.4. Bot-Mitigation Handover (Cloudflare / reCAPTCHA)

**Problem.** A script needs to log into a public web dashboard (e.g., a DNS provider, a certificate authority) that is behind Cloudflare's bot mitigation. The Cloudflare challenge cannot be solved headlessly because it requires either image recognition or a real browser fingerprint. The script must run unattended most of the time, but when the challenge appears, a human needs to be involved.

**Solution.** HoTMetaL's `human` command serializes the session cookies, tears down the headless Chromium instance, opens a visible browser window with the same cookies, and prompts the operator to solve the challenge. When they press Enter, the visible window's cookies are captured and the headless browser is restored with the solved session.

```powershell
.\CLI-Browser.ps1 "https://dash.cloudflare.com" `
    -Exec 'go; "Email"=env:CF_EMAIL; "Password"=env:CF_PASS; "Sign In"; expect Dashboard; text'
```

If the challenge appears, the browse mode displays a `human` line in the item list, and the operator can press `v` (or Enter on that line) to trigger the handover. In script mode, the `human` command can be added to the `-Exec` string.

**Why this works.** This is the tool's most distinctive capability. No other PowerShell-native tool supports "run headless until you hit a bot check, then hand over to the operator, then resume headless." Selenium can technically do this with `webdriver.Chrome(options=...)` and manual cookie injection, but the code to do it is nontrivial and the resulting script is no longer a script—it's a framework.

**Important limitation.** The `human` command requires an interactive session. On a Datto RMM endpoint with no interactive user, it will fail with a clear error message. This is by design: it is not a magic bullet for fully unattended bot-check bypass; it is a tool for the case where most runs are unattended but some need a human.

### 3.5. Incident Response (Emergency Isolation)

**Problem.** A security incident requires immediate isolation of a compromised server's network access. The firewall's "Block Traffic" policy must be enabled within minutes. The operator is under pressure, at 3 AM, possibly on call from home, with only a laptop and VPN access.

**Solution.** A pre-written HoTMetaL script that toggles the isolation policy:

```powershell
.\CLI-Browser.ps1 "https://$fw`:4443" `
    -Exec '"Username"=env:FW_USER; "Password"=env:FW_PASS; "Login"; expect Dashboard; "Firewall"; "IPv4 Policy"; expect "Server-Isolation"; "Server-Isolation"=on; "OK!"; expect "enabled"; "Logout"' `
    -Dump
```

The `!` after `"OK"` answers the confirmation dialog with OK, which is the intended action for an isolation command. Without the `!`, the dialog defaults to CANCEL and the script fails—which is the correct behavior for a command this destructive.

**Why this works.** The `expect "enabled"` assertion is the safety net. If the policy was not actually enabled (e.g., the operator clicked the wrong row, or the firewall rejected the change due to a configuration lock), the script exits with code 1 and the incident responder sees the failure immediately. The `-Dump` output logs the final state so the responder can verify it independently.

### 3.6. Multi-Vendor Console Unification

**Problem.** An organization runs three firewall vendors—FortiGate, SonicWall, and WatchGuard—across different sites. Each has a different web UI. The security team wants a single command that produces "the current state of all outbound policies" across all three.

**Solution.** Three wrapper scripts sharing a common output schema:

```powershell
# fortigate-policies.ps1
.\CLI-Browser.ps1 "https://$fw`:4443" -Exec "$fortigate_script" -Dump | ConvertFrom-FortigateGrid

# sonicwall-policies.ps1
.\CLI-Browser.ps1 "https://$fw`:4433" -Exec "$sonicwall_script" -Dump | ConvertFrom-SonicwallGrid

# watchguard-policies.ps1
.\CLI-Browser.ps1 "https://$fw`:8080" -Exec "$watchguard_script" -Dump | ConvertFrom-WatchguardGrid
```

Each wrapper uses `Format-CliText`'s column alignment to parse the rendered grid into structured objects. The common output schema is defined by the organization, not by the vendor.

**Why this works.** The uniformity of HoTMetaL's output—tab-separated tables aligned into columns—means a single parser works for all three vendors. Selenium would require writing and maintaining three separate scraping scripts; `Invoke-WebRequest` cannot render the pages at all.

### 3.7. CI/CD Verification of Firewall Configuration

**Problem.** A team uses Terraform to provision firewall policies. Terraform's FortiGate provider covers most policy fields, but the rendered policy list—what a human sees in the UI—is Terraform's blind spot. A Terraform apply can succeed while leaving the UI in a state that a human operator would consider wrong (e.g., the policy appears shadowed, or the source address is not what was intended).

**Solution.** A post-apply verification step in the CI/CD pipeline:

```powershell
.\CLI-Browser.ps1 "https://$fw`:4443" `
    -Exec '"Username"=env:FW_USER; "Password"=env:FW_PASS; "Login"; "Firewall"; "IPv4 Policy"; text' `
    -Dump | Select-String -Pattern 'Shadow' -NotMatch

if ($LASTEXITCODE -ne 0) {
    Write-Error "Post-apply verification failed: policy rendering mismatch"
    exit 1
}
```

**Why this works.** The `text` command renders the page's text, including the "Shadow" indicator that the FortiGate UI adds to policies that are shadowed by earlier rules. This is a piece of state that Terraform's API does not expose. The pipeline catches the mismatch before it reaches production.

### 3.8. AI Agent Browser Driver

**Problem.** An autonomous LLM agent needs to drive a browser to complete a task (e.g., "log into the SaaS dashboard and export the user list as CSV"). The agent must be able to inspect the page state, emit a command, and verify the effect—all through a well-defined interface.

**Solution.** The agent calls HoTMetaL's command grammar via `-Exec` and parses the `snap` output:

```powershell
$snap = .\CLI-Browser.ps1 "https://dash.saas-vendor.com" -Exec 'text' -Dump

# Agent examines $snap for a "Sign In" button, then calls:
.\CLI-Browser.ps1 "https://dash.saas-vendor.com" -Exec '"Email"=...; "Password"=...; "Sign In"; expect Dashboard; "Users"; "Export"; "CSV"; dl' -Dump
```

**Why this works (and why it's not fully solved).** The `expect` assertion makes the agent's task verifiable: the agent can retry a step or report failure based on exit code. The `-Dump` output is a stable, text-based page representation the agent can reason about. The limitations are real: the agent must know enough about the site to construct the command string, and the tool has no built-in "read the page and decide what to do" capability. HoTMetaL is the execution primitive, not the decision layer. This is a deliberate design choice—the decision layer is where LLM error rates are highest, and putting it in a separate component keeps the failure modes legible.

---

## 4. Architectural Innovations

The following are the design decisions that make the use cases possible. Not all are novel—Selenium has fingerprinting, Playwright has shadow DOM, Browsh has dialog interception—but the combination is what makes HoTMetaL work as a PowerShell-native tool.

### 4.1. The Kernel as a Single Effect Primitive

The core architectural insight: all browser interaction goes through one JavaScript function, `kernel(op, args)`, which exposes a small, stable vocabulary.

```javascript
const ops = {
    install: () => { ... },      // hook dialogs, network, mutations
    snap:    () => { ... },      // enumerate the page into a numbered list
    act:     () => { ... },      // click, fill, select, submit, opts
    settle:  () => { ... },      // wait for quiescence
    text:    () => { ... },      // extract readable text
    arm:     () => { ... },      // enable confirm() = OK
    disarm:  () => { ... },      // disable confirm() = OK
    mark:    () => { ... },      // tag an element for upload
    consent: () => { ... },      // click a cookie banner (on request)
    rect:    () => { ... },      // get element position (for real mouse events)
    html:    () => { ... },      // extract raw markup
    editfor: () => { ... },      // find the "Edit" button for a selected row
    chunk:   () => { ... }       // pull a large result in pieces
};
```

This has three consequences:
1. **The effect surface is auditable.** Every interaction with the browser is in one 800-line function. A security review has one thing to read, not twenty.
2. **The pure/effect boundary is clear.** Everything outside the kernel is deterministic PowerShell that can be unit-tested without a browser. The `Test-CliOffline` suite has 40+ tests, none of which need Chromium.
3. **The fingerprint is naturally consistent.** Because `snap` and `act` share state through `__cliState`, the fingerprint stored at snapshot time is checked at action time. A tool that stored fingerprints in PowerShell and passed them back would have a serialization boundary that could go wrong.

This is the single biggest architectural difference from Selenium/Playwright, which expose a large surface (`find_element_by_xpath`, `find_elements_by_css_selector`, `find_element_by_link_text`, ...) rather than a single primitive. The large surface is more flexible; the single primitive is easier to reason about and safer by default.

### 4.2. Fingerprint Verification with Stale-Safe Failure

Every numbered item in the list carries a fingerprint:

```text
kind | tag | label | name
```

Before acting on item $n$, the kernel verifies:
1. The item exists in the current list (bounds check).
2. The item is still in the DOM (`el.isConnected`).
3. The kind has not changed (`kindOf(el)`).
4. The fingerprint matches the stored value.

If any check fails, the action is refused with a `stale` or `changed` error. This is what prevents "the script clicked the wrong thing because the page renumbered its rows."

```javascript
const resolve = () => {
    if (A.gen && String(A.gen).split(':')[0] !== S.sid)
        return { err: 'stale', msg: 'that list belongs to a previous page (run ls)' };
    const el = S.refs[(A.i | 0) - 1];
    if (!el) return { err: 'stale', msg: 'no item ' + A.i + ' ...' };
    if (!el.isConnected) return { err: 'stale', msg: 'item ' + A.i + ' is no longer on the page' };
    const k = kindOf(el);
    if (A.gen && A.gen !== S.sid + ':' + S.gen)
        return { err: 'stale', msg: 'the list you used is out of date' };
    if (fpOf(el, k) !== S.fps[(A.i | 0) - 1])
        return { err: 'changed', msg: 'item ' + A.i + ' changed since it was listed' };
    return { el: el, k: k };
};
```

The alternative—acting on whatever is currently at position $n$—is what produces the class of bug where a script updates the wrong firewall policy because the sort order changed between the `ls` and the `act`. This is a real problem for firewall automation, where a policy named "Allow-SSH" and a policy named "Deny-SSH" can be swapped by adding a single row.

### 4.3. Dialogs as Data, Not as Blocks

`window.alert`, `window.confirm`, and `window.prompt` are replaced at install time:

```javascript
w.alert = function (m) { S.dlg.push({ t: 'alert', m: txt(m) }); };
w.confirm = function (m) {
    const ok = S.armed > 0;
    S.dlg.push({ t: 'confirm', m: txt(m), r: ok });
    return ok;
};
w.prompt = function (m, d) {
    const v = (S.promptAnswer != null) ? String(S.promptAnswer) : null;
    S.dlg.push({ t: 'prompt', m: txt(m), r: v != null });
    return v;
};
```

The consequences:
- **No blocking.** `alert()` returns immediately; the dialog is queued for the calling code to inspect.
- **Safe by default.** `confirm()` returns false (Cancel) unless `arm()` has been called. This means a script that clicks a "Reboot" button without the `!` modifier will get a cancelled confirmation, not an accidental reboot.
- **Local scope.** The `!` modifier on a command sets `S.armed = 1` for that command only; `Wait-Settle` calls `disarm()` to reset it. A subsequent command without `!` gets the safe default.
- **Auditable.** Every dialog is logged: `CONFIRM cancelled: Reboot now?` or `CONFIRM answered OK: Reboot now?`

Compare to Selenium, where `driver.switch_to.alert.accept()` blocks the WebDriver session, and to Playwright, where dialogs require explicit `page.on('dialog', ...)` handlers that must be set up before the dialog fires. Both are workable; neither is as safe-by-default as "Cancel unless explicitly overridden."

The `!` design is particularly important for the incident-response use case (§3.5). A responder under pressure who types "OK" without `!` gets a clear failure (the confirmation was cancelled), not a destructive action. A responder who types "OK!" has explicitly authorized the destructive action.

### 4.4. Human-in-the-Loop Handover

The `human` command is the most novel capability. The implementation:
1. Serialize all cookies via `Network.getAllCookies` (not just the current page's, because Cloudflare sets cookies on `.cloudflare.com` that are needed on `.example.com`).
2. Close the headless browser.
3. Launch a visible Chromium instance with the serialized cookies.
4. Navigate the visible window to the current page.
5. Prompt the operator to solve the challenge.
6. On Enter, capture the visible window's cookies via `Network.getAllCookies`.
7. Close the visible window.
8. Relaunch the headless browser.
9. Restore all tabs with the captured cookies.
10. Navigate to the target URL (either the original challenge URL or the post-challenge page).

This is a genuinely novel capability. No other PowerShell-native tool does it. The closest equivalent is Selenium's `webdriver.Chrome()` with `--user-data-dir`, which carries cookies across launches but requires the operator to manually close and reopen the browser—and the script has no way to know whether the challenge was solved.

The design tradeoff: `human` requires an interactive console. It will fail with a clear error message on a Datto RMM endpoint with no logged-in user. This is correct: bypassing a bot check requires a human, and pretending otherwise would be dishonest.

### 4.5. jqGrid and Firewall-Specific Table Detection

The kernel's `isDataRow` function identifies rows that are part of a real data table (as opposed to layout tables, header tables, or nested-table structures):

```javascript
function isDataRow(el) {
    if (el.closest('thead')) return false;
    const tbl = el.closest('table,[role="grid"],[role="table"],[role="treegrid"]');
    if (!tbl) return false;
    if (el.querySelector('table')) return false;      // a container, not a data row
    const grid = JQROW.test(el.className) || tbl.matches('[role="grid"],[role="treegrid"],.ui-jqgrid-btable,.dataTable');
    const ownHead = Array.prototype.some.call(tbl.querySelectorAll('th,[role="columnheader"]'), ...);
    if (!grid && !ownHead) return false;
    let cells = 0;
    for (const c of el.children) { ... }
    return cells > 0 && txt(el.innerText).length > 0;
}
```

The key detail is `headerRowFor`:

```javascript
const headerRowFor = (row) => {
    const tbl = row.closest('table,[role="grid"],...');
    if (!tbl) return null;
    let th = tbl.querySelector('thead th,[role="columnheader"]');
    if (!th) {
        const box = row.closest('.ui-jqgrid');
        if (box) th = box.querySelector('.ui-jqgrid-htable th,[role="columnheader"]');
    }
    ...
};
```

This handles jqGrid's peculiar architecture, where the header table (`.ui-jqgrid-htable`) is a separate `<table>` from the body table (`.ui-jqgrid-btable`). A generic "find the `<thead>`" heuristic would miss the headers entirely. The jqGrid-specific case is what makes FortiGate, WatchGuard, and SonicWall grids legible.

The `rowCells` function combines cell text into a single label (`admin | Device Administrator | Enabled`), and `valueOf` detects selection state via CSS class (`ui-state-highlight`) as well as `aria-selected`:

```javascript
if (k === 'row') {
    const sel = el.getAttribute('aria-selected') === 'true'
             || /(^|[\s_-])(selected|active|highlight(ed)?|checked)([\s_-]|$)/i.test(el.className || '')
             || !!el.querySelector('input[type="checkbox"]:checked,input[type="radio"]:checked');
    return sel ? 'on' : 'off';
}
```

This is what makes "Enter on a row selects it; Enter again opens it" work for firewalls, and it's what makes the "Open row" workflow in `Open-CliRow` succeed where naive double-click emulation fails.

### 4.6. Media Detection

For general-web use cases (news, documentation, SaaS dashboards), HoTMetaL classifies links as video or audio based on URL patterns:

```javascript
const VIDEO_URL = /\/videos?\/|\/watch\b|youtube\.com\/|youtu\.be\/|vimeo\.com\/\d|.../i;
const AUDIO_URL = /\/(audio|podcasts?|radio|listen)\/|\.(mp3|m4a|aac|ogg|...)/i;
```

And flags pages where the main content is a player:

```javascript
const pageMedia = () => {
    let v = 0, a = 0;
    document.querySelectorAll('video').forEach(e => { ... });
    document.querySelectorAll('iframe').forEach(f => {
        if (/youtube\.com\/embed|player\.vimeo|.../.test(f.src)) v++;
    });
    ...
};
```

The result is that a user browsing a news site sees:

```text
[VIDEO] Disney prices are up 20% this year
[AUDIO] Episode 12: The future of AI
[LINK]  A story about something else
```

And a page whose main content is a video shows:

```text
VIDEO page: the main content is a video player - there may be little or no text.
```

This is a small innovation but a real one for the use case "browse the news from a terminal." It's also a genuinely useful signal for an AI agent that needs to know "this page is not readable, find the transcript."

### 4.7. Ambiguity Refusal

`Resolve-CliLabel`:

```powershell
function Resolve-CliLabel($items, [string]$label) {
    $l = $label.Trim().ToLowerInvariant()
    $exact = @($items | Where-Object { "$($_.l)".Trim().ToLowerInvariant() -eq $l })
    if ($exact.Count -eq 1) { return @{ Hit = $exact[0] } }
    if ($exact.Count -gt 1) { return @{ Ambiguous = $exact } }
    $sub = @($items | Where-Object { "$($_.l)".ToLowerInvariant().Contains($l) })
    if ($sub.Count -eq 1) { return @{ Hit = $sub[0] } }
    if ($sub.Count -gt 1) { return @{ Ambiguous = $sub } }
    return @{}
}
```

Two behaviors:
1. **Exact match beats substring.** "Login" matches the item labelled Login, not the item labelled Login with SSO.
2. **Ambiguity is an error, not a guess.** "pass" matches Password, Passphrase, and Forgot password? and the tool refuses to act, listing all matches for the user to choose from.

Compare to Selenium's `find_element_by_link_text`, which raises an exception on multiple matches, or `find_element_by_partial_link_text`, which picks the first. The first is safe but inflexible; the second is dangerous. HoTMetaL is safe and flexible—the user resolves the ambiguity by number, not by accepting a guess.

This is not technically novel (it's the obvious correct behavior), but it's a design property that many automation tools get wrong. It matters for firewall automation: on a WatchGuard policy table, "Any-Trusted" and "Any-Optional" are distinct source addresses, and picking the wrong one is a silent misconfiguration.

### 4.8. Contextual Button Naming

Firewall UIs frequently have multiple buttons labelled the same thing. FortiGate has "Add" for policies, "Add" for addresses, "Add" for users, "Add" for VPN portals. WatchGuard has "Add" and "Remove" on both sides of a from/to list editor.

`snap` disambiguates these:

```javascript
const groups = {};
items.forEach(it => { if ((it.k === 'btn' || it.k === 'a') && counts[it.l] > 1) (groups[it.l] = groups[it.l] || []).push(it); });
Object.keys(groups).forEach(label => {
    const g = groups[label];
    const heads = g.map(it => headingFor(S.refs[it.i - 1]));
    const distinct = new Set(heads.filter(Boolean)).size === g.length;
    g.forEach((it, x) => {
        let sfx = distinct ? heads[x] : '';
        if (!sfx) { const hint = idHint(S.refs[it.i - 1], label); sfx = hint || heads[x]; }
        if (sfx) it.l = (label + ' (' + sfx + ')').slice(0, 120);
    });
});
```

The result: buttons labelled `Add (Firebox Users)`, `Add (Firebox Groups)`, `Add (From)`, `Add (To)`. The user (or the script) can address them by full label or by number, and there is no ambiguity.

This is a small thing that makes a huge difference in practice. Without it, a script that wants to click "the Add button in the From section" has to enumerate buttons by index—which changes the moment the page changes.

### 4.9. The settle Algorithm

Waiting for a page to be "ready" is harder than it looks. `document.readyState === 'complete'` fires before XHR fetches resolve. MutationObserver fires for every attribute change, including ones that don't matter. Long-poll pages never reach a quiet state.

`settle` combines three signals:

```javascript
settle: () => {
    install(window);
    let rs = document.readyState;
    for (const f of document.querySelectorAll('iframe,frame')) {
        try { const d = f.contentDocument; if (d && d.readyState !== 'complete') rs = d.readyState; } catch (e) {}
    }
    const leaving = S.leaving ? (Date.now() - S.leaving) : 0;
    return { rs: rs, p: S.pending, m: S.mut, lv: leaving, url: location.href, dlg: drain() };
}
```

And `Wait-Settle` in PowerShell:

```powershell
if ($r.rs -eq 'complete' -and -not $leaving) {
    if ([long]$r.m -eq $lastM) {
        if ($quiet -lt 0) { $quiet = $sw.ElapsedMilliseconds }
        $q = $sw.ElapsedMilliseconds - $quiet
        if (([int]$r.p -eq 0 -and $q -ge 300) -or $q -ge 1500) { $settled = $true; break }
    } else { $quiet = -1 }
    $lastM = [long]$r.m
}
```

The rule: complete document + zero pending XHR/fetch + 300ms of no mutation is "settled." If XHR/fetch never reaches zero (long-poll), 1500ms of no mutation also counts.

This is not a novel algorithm—Playwright's `waitForLoadState` and Cypress's wait-for-network-idle do similar things. But the combination of DOM mutation + network + a fallback for long-poll is tuned for the firewall case, where "the policy table is loaded" is often signalled by a DOM mutation with no network activity at all.

---

## 5. What Is Not Novel

It is worth being explicit about what is engineering rather than invention, because the papers risk overclaiming:
- **Shadow DOM traversal.** Playwright, Puppeteer, and Selenium all support it. HoTMetaL's implementation is clean but not unique.
- **Dialog interception.** Cypress, Playwright, and Selenium 4 all support dialog handlers. The "default to Cancel" behavior is a design choice, not an invention.
- **Wait for quiescence.** Standard across modern frameworks.
- **URL normalization.** Trivial.
- **Bookmarks, tab management, screenshots, PDF export.** Standard browser features.
- **The `-Exec` / `-Run` / `-Dump` interface.** Similar to `lynx -dump` and to Selenium's `driver.get_page_source()`.
- **Fingerprint verification.** Cypress has "retry-ability" via `should`; Playwright has element staleness checks. HoTMetaL's fingerprint is a specific implementation, not a new concept.

The genuinely novel contributions are:
1. **The kernel-as-single-primitive.** This is a design choice that most frameworks don't make—they expose a large API instead. The choice has real benefits (auditability, testability) and real costs (less flexibility than a full API).
2. **The human-in-the-loop handover.** I have not seen another PowerShell-native tool that does this.
3. **The jqGrid-specific table detection.** Standard DOM traversal tools don't have this; it's tuned for the specific class of firewall UIs.
4. **The combinatorial constraint set.** The tool does not just have individually novel features—it has a specific combination (PowerShell-native + headless + shadow DOM + dialogs-as-data + fingerprint + human-in-the-loop + jqGrid + algebraic grammar) that no other tool matches.

This matters because the user is not choosing between "HoTMetaL" and "a slightly better HoTMetaL." They are choosing between "HoTMetaL" and "no viable option at all" for a substantial set of problems.

---

## 6. Limitations

An honest paper lists what the tool does not do:
- **File uploads inside iframes are refused.** The `mark` op returns `err: 'frame'` for elements inside a frame. This is because Pup's `Send-PupFile` requires a top-level page handle. Workaround: navigate directly to the frame's URL and upload from there.
- **Cross-origin iframes are enumerated but not interacted with.** The `snap` output lists them (`frames` command shows details), but their contents are inaccessible. This is a browser security boundary, not a HoTMetaL limitation.
- **`human` requires an interactive console.** No workaround for fully unattended bot-check bypass. This is by design.
- **No WebSocket or Service Worker introspection.** The settle counter tracks fetch and XMLHttpRequest but not WebSocket or `navigator.sendBeacon`. On pages that use these exclusively, settle will time out.
- **No support for `beforeunload` dialogs.** The kernel hooks `beforeunload` only to record `S.leaving`, not to answer the dialog. Navigating away from a page with unsaved changes will trigger Chrome's native `beforeunload` dialog, which PuppeteerSharp handles by default-accepting. This is a small correctness gap.
- **No support for HTTP/2 server push, HTTP/3, or non-TLS-by-default enterprise proxies.** These are browser-level features, but the tool's assumption is "the browser works"; if the browser doesn't work in an environment, HoTMetaL doesn't either.
- **Performance on very large pages.** `snap` limits to 600 items; `text` chunks large results at 12 KB. A page with 10,000 interactive elements will not be fully enumerated in one pass. For firewall UIs this is not a practical limit; for some SaaS consoles it might be.
- **Install footprint.** Chromium is ~150 MB. This is smaller than Playwright but not zero. On endpoints with AppLocker restrictions that block Chromium's subprocess spawning, HoTMetaL will fail at `Start-PupBrowser` and there is no lightweight fallback.
- **The `-Dump` output is not JSON.** It is tab-separated text. This is easy to parse but not a formal schema. A `-Json` output mode would improve downstream usability, but does not exist yet.

---

## 7. Comparison to the Alternatives, Revisited

To summarize the positioning:
- **vs. Selenium / Playwright:** HoTMetaL is smaller, PowerShell-native, and produces structured text output without requiring a scripting language runtime. Selenium is more flexible, more portable across languages, and better documented. HoTMetaL is the better choice when "it must run in a Datto RMM component job on Windows" is a hard constraint; Selenium is the better choice when flexibility matters more than deployment.
- **vs. Invoke-WebRequest:** HoTMetaL handles JavaScript; `Invoke-WebRequest` does not. For sites that only serve static HTML, `Invoke-WebRequest` is faster and simpler. For everything else, HoTMetaL is the only option.
- **vs. Lynx / w3m:** HoTMetaL handles SPAs; Lynx and w3m do not. For static content, Lynx is smaller and faster. For interactive content, HoTMetaL is the only option.
- **vs. Browsh:** Browsh is for humans; HoTMetaL is for scripts. Browsh is better at rendering complex visual layouts. HoTMetaL is better at producing structured, parseable output.
- **vs. writing a Python Playwright script:** The Python script is more flexible and probably shorter for a one-off task. But it requires Python, `pip install playwright`, `playwright install`, and a maintenance plan for Python version updates. HoTMetaL requires PowerShell (already present) and the Pup module (installed on first run). For an RMM environment, the deployment cost difference is significant.

The honest summary: HoTMetaL is the best tool for a specific intersection of constraints (PowerShell, headless, interactive web UI, audit-required), not the best tool for all browser automation. The papers should say so.

---

## 8. Conclusion

The problems HoTMetaL solves are real and underserved:
- Firewall console automation is a category of task where REST APIs are incomplete, WebDriver frameworks are too heavy, and `Invoke-WebRequest` cannot render the page. The MSP use case (§3.1, §3.2) is the canonical example, and the tool is designed from the ground up for it.
- RMM automation environments impose constraints (no desktop, no runtime installation, PowerShell-only) that disqualify most browser automation tools. HoTMetaL is one of the few tools that fits rather than requiring the environment to adapt.
- Bot-mitigation handover is a capability no other PowerShell-native tool provides. It is a hybrid manual/automated workflow, not a bypass, and its limitations are honest.
- AI-agent browser driving is a use case that the design constraints (numbered namespace, dialogs-as-data, expect assertions, structured dump output) are naturally suited to. This is not the primary use case but it is a real one.

The architectural innovations—kernel as single primitive, fingerprint verification, dialogs-as-data, human-in-the-loop, jqGrid table detection, ambiguity refusal—are the reasons the use cases are possible. Individually, most are not novel. In combination, they produce a tool that does not have a direct equivalent.

The tool has real limitations (iframe file uploads, cross-origin iframes, human requiring interactivity, 150 MB install footprint, no JSON output). These are documented, not hidden. The tool works within its design constraints and fails honestly when it encounters their edges.

The papers should not oversell this as "the future of browser automation." It is a well-engineered solution to a specific class of problem—driving interactive web UIs from a PowerShell-native, headless, auditable context—that has been underserved for a decade. That is a significant and useful thing to be.

---

## Appendix A: A Complete Working Example

For readers who want to see the tool end-to-end, here is a complete script that demonstrates every major feature. It is not a real firewall automation (it uses a `data:` URL for reproducibility), but the structure is exactly what a production script would look like.

```powershell
# demonstrate.ps1
# A complete walkthrough of HoTMetaL's capabilities.
# Run: .\CLI-Browser.ps1 -SelfTest  (to verify the tool works)
# Then run this script.

$demo = @'
<html><head><title>Demo</title></head><body>
  <h1>Demo Page</h1>
  <nav>
    <a href="#a">Section A</a>
    <a href="#b">Section B</a>
    <a href="#c">Section C</a>
    <a href="#d">Section D</a>
    <a href="#e">Section E</a>
    <a href="#f">Section F</a>
    <a href="#g">Section G</a>
    <a href="#h">Section H</a>
    <a href="#i">Section I</a>
    <a href="#j">Section J</a>
    <a href="#k">Section K</a>
    <a href="#l">Section L</a>
  </nav>
  <table id="users">
    <thead><tr><th>Name</th><th>Role</th></tr></thead>
    <tbody>
      <tr><td>alice</td><td>Admin</td></tr>
      <tr><td>bob</td><td>Viewer</td></tr>
    </tbody>
  </table>
  <button onclick="if (confirm('Really delete alice?')) { document.body.setAttribute('data-deleted', 'yes'); document.title = 'Deleted'; }">Delete Alice</button>
</body></html>
'@

$dataUrl = 'data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($demo))

# 1. Navigate and inspect: p shows the page, ls shows specific kinds of items.
.\CLI-Browser.ps1 $dataUrl -Exec 'p' -Dump

# 2. Enumerate interactive items and read the page.
.\CLI-Browser.ps1 $dataUrl -Exec 'ls; text' -Dump

# 3. Click without ! - the confirm dialog is Cancel by default.
.\CLI-Browser.ps1 $dataUrl -Exec '"Delete Alice"; p' -Dump
# (title remains "Demo"; no data-deleted attribute)

# 4. Click with ! - the confirm dialog answers OK.
.\CLI-Browser.ps1 $dataUrl -Exec '"Delete Alice"!; p' -Dump
# (title becomes "Deleted"; data-deleted="yes")

# 5. Select a table row - the first Enter selects it.
.\CLI-Browser.ps1 $dataUrl -Exec '"alice"; p' -Dump
# (row shows as selected)

# 6. Use expect to assert the click did what you expected.
.\CLI-Browser.ps1 $dataUrl -Exec '"Delete Alice"!; expect Deleted; text' -Dump

# 7. Chain multiple commands; a failure stops the chain.
.\CLI-Browser.ps1 $dataUrl -Exec '"Nonexistent Button"; "Delete Alice"!' -Dump
# (the first command fails, so the second never runs - exit code 1)
```

The last example (§7) is the most important. The `;` sequencing means a script stops at the first failure. This is what makes macros safe for production use: if any step fails, no subsequent step can accidentally run.

---

## Appendix B: The Command Grammar

For reference, the complete grammar as of v6.2:

```text
# Addressing
12                         activate item 12 (click/toggle/prompt for value)
"Label"                    activate by label (exact, else unique substring)
12!                        activate, answer OK to any confirm() dialog
4=admin                    set item 4 to "admin"
4=?                        set item 4, prompting without echo
4=env:FWPASS               set item 4 from environment variable FWPASS
7=on / 7=off               checkbox on/off
9=port3                    select option by text (or 9=#2 by index)
12=on                      select table row 12

# Navigation
go <target> / <target>     navigate to URL or host:port
@bookmark                  navigate to bookmark
b / back                   browser back
f / fwd                    browser forward
reload                     reload current page

# Inspect
p / page                   show the page (numbered items)
ls [filter]                list items (filter: in|btn|a|sel|chk|menu|row or substring)
r / read                   read the article body (if any)
text                       read the whole page as text
find <pattern>             search the page text
opts <n>                   show options for a dropdown
frames                     list iframes
cert                       show TLS certificates
savehtml [file]            save raw HTML

# Forms
type <n> <text>            type into field
secret <n>                 type secret into field (no echo)
submit [n]                 submit the form containing item n
enter                      press Enter
key <name>                 press a specific key (Tab, Escape, ArrowDown, ...)
upload <n> <file>          upload a file to a file input

# Interaction
click <n>                  alias for <n>
consent                    click a cookie banner (on request)
human                      open a visible browser for a challenge

# Tabs
tabs                       list tabs
tab <n>                    switch to tab n
new [target]               open a new tab
close                      close current tab

# Bookmarks
bm                         list bookmarks
bm add <name> [url]        add a bookmark
bm del <name>              delete a bookmark
bm <name>                  navigate to bookmark

# Scripting
a ; b ; c                  sequence (b runs only if a succeeds)
run <file>                 run a script file
expect <pattern>           wait for text to appear; fail if timeout
wait <seconds>             sleep for N seconds

# Output
shot [file.png]            take a screenshot
pdf [file.pdf]             save as PDF
dl [dir]                   show download directory

# Misc
auth <user> | auth clear   HTTP Basic auth
debug                      show diagnostic info
log                        show recent log
help                       show help
quit                       exit
```

*End of whitepaper.*