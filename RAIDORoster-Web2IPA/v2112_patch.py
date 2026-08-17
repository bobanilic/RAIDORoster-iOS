from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
WEBVIEW = ROOT / "RAIDORoster" / "RosterWebView.swift"
JS = ROOT / "RAIDORoster" / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.2 patch marker not found: {label}")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# Native browser bridge: one-tap historical backfill with progress reporting.
# The JS does the month traversal; each validated month continues through the
# existing rosterCache bridge, where V2.11 indexes it as history-only.
# -----------------------------------------------------------------------------
web = WEBVIEW.read_text()
web = replace_once(
    web,
    '''    @Published var diagnosticStatus: String?\n''',
    '''    @Published var diagnosticStatus: String?\n    @Published var historyBackfillStatus: String?\n    @Published var historyBackfillRunning = false\n''',
    "browser history state"
)

web = replace_once(
    web,
    '''    func copyDiagnostics() {\n''',
    '''    func backfillCrewHistory() {\n        guard let webView else {\n            historyBackfillRunning = false\n            historyBackfillStatus = "Open the RAIDO tab first, then try again."\n            return\n        }\n\n        historyBackfillRunning = true\n        historyBackfillStatus = "Starting RAIDO history scan…"\n        let script = """\n        (() => {\n          if (!window.RAIDOPlus || typeof window.RAIDOPlus.backfillCrewHistory !== 'function') return false;\n          window.RAIDOPlus.backfillCrewHistory();\n          return true;\n        })();\n        """\n        webView.evaluateJavaScript(script) { result, error in\n            DispatchQueue.main.async {\n                if let error {\n                    self.historyBackfillRunning = false\n                    self.historyBackfillStatus = "Could not start history scan: \\(error.localizedDescription)"\n                } else if (result as? Bool) != true {\n                    self.historyBackfillRunning = false\n                    self.historyBackfillStatus = "Open the RAIDO roster page and let it load, then try again."\n                }\n            }\n        }\n    }\n\n    fileprivate func handleHistoryBackfillMessage(_ body: Any) {\n        guard let payload = body as? [String: Any],\n              let state = payload["state"] as? String else { return }\n\n        let label = payload["monthLabel"] as? String ?? payload["month"] as? String ?? ""\n        let scanned = payload["scanned"] as? Int ?? 0\n\n        switch state {\n        case "started":\n            historyBackfillRunning = true\n            historyBackfillStatus = label.isEmpty ? "Scanning RAIDO roster history…" : "Scanning backward from \\(label)…"\n        case "progress":\n            historyBackfillRunning = true\n            historyBackfillStatus = label.isEmpty\n                ? "Indexed \\(scanned) RAIDO month\\(scanned == 1 ? "" : "s")…"\n                : "Indexed \\(label) • \\(scanned) month\\(scanned == 1 ? "" : "s")"\n        case "restoring":\n            historyBackfillRunning = true\n            historyBackfillStatus = "History indexed • returning to your roster month…"\n        case "complete":\n            historyBackfillRunning = false\n            let restored = payload["restored"] as? Bool ?? false\n            let reason = payload["reason"] as? String ?? ""\n            if restored {\n                historyBackfillStatus = "Crew history backfill complete • \\(scanned) RAIDO month\\(scanned == 1 ? "" : "s") indexed"\n            } else {\n                historyBackfillStatus = "History indexed, but RAIDO could not automatically return to the starting month. Open the current month before syncing again."\n            }\n            if !reason.isEmpty && reason != "earliest" && reason != "limit" {\n                historyBackfillStatus? += " • \\(reason)"\n            }\n        case "error":\n            historyBackfillRunning = false\n            historyBackfillStatus = payload["message"] as? String ?? "RAIDO history scan failed."\n        default:\n            break\n        }\n    }\n\n    func copyDiagnostics() {\n''',
    "browser history methods"
)

web = replace_once(
    web,
    '''        controller.add(context.coordinator, name: "rosterCache")\n''',
    '''        controller.add(context.coordinator, name: "rosterCache")\n        controller.add(context.coordinator, name: "historyBackfill")\n''',
    "history message handler registration"
)

web = replace_once(
    web,
    '''        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {\n            guard message.name == "rosterCache" else { return }\n            Task { @MainActor in\n                self.model.store.ingest(messageBody: message.body)\n            }\n        }\n''',
    '''        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {\n            if message.name == "historyBackfill" {\n                Task { @MainActor in self.model.handleHistoryBackfillMessage(message.body) }\n                return\n            }\n            guard message.name == "rosterCache" else { return }\n            Task { @MainActor in\n                self.model.store.ingest(messageBody: message.body)\n            }\n        }\n''',
    "history bridge dispatch"
)
WEBVIEW.write_text(web)


# -----------------------------------------------------------------------------
# Settings: a single explicit backfill action. It switches to the already-
# authenticated RAIDO tab and then starts traversal. This is intentionally not
# silent/background automation because RAIDO is the live authenticated source.
# -----------------------------------------------------------------------------
content = CONTENT.read_text()
content = content.replace(
    '''                    LabeledContent("Crew history months", value: "\\(store.crewHistoryMonths.count)")\n''',
    '',
    1
)

history_section = r'''
                Section("Crew history") {
                    LabeledContent("Indexed RAIDO months", value: "\(store.crewHistoryMonths.count)")

                    Button {
                        openPortal()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                            browser.backfillCrewHistory()
                        }
                    } label: {
                        Label(
                            browser.historyBackfillRunning ? "Scanning RAIDO history…" : "Backfill previous RAIDO months",
                            systemImage: browser.historyBackfillRunning ? "arrow.triangle.2.circlepath" : "clock.arrow.trianglehead.counterclockwise.rotate.90"
                        )
                    }
                    .disabled(browser.historyBackfillRunning)

                    if let status = browser.historyBackfillStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Uses RAIDO's Previous/Next month controls to index validated historical rosters. Historical months update crew flying history only; they do not replace your active offline roster, Calendar, reminders, or roster-change state.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

'''
content = replace_once(
    content,
    '''                Section("Portal") {\n''',
    history_section + '''                Section("Portal") {\n''',
    "crew history settings section"
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.1")',
    'LabeledContent("RAIDO Roster", value: "2.11.2")',
    1
)
CONTENT.write_text(content)


# -----------------------------------------------------------------------------
# RAIDO month traversal. Parser/build/validation functions are reused as-is.
# We click only the exact controls discovered by the V2.11.1 diagnostic:
# BUTTON.switch-month-button with text Previous / Next.
# -----------------------------------------------------------------------------
js = JS.read_text()
backfill_js = r'''
  let historyBackfillRunning = false;

  function historyBackfillMessage(payload) {
    try {
      window.webkit?.messageHandlers?.historyBackfill?.postMessage(payload);
    } catch (_) {}
  }

  function monthKey(value) {
    if (!value || !value.year || !value.month) return '';
    return `${value.year}-${pad2(value.month)}`;
  }

  function switchMonthButton(direction) {
    const wanted = upper(direction);
    return Array.from(document.querySelectorAll('button.switch-month-button')).find(button => {
      const label = upper(button.innerText || button.textContent || button.value || '');
      return label === wanted;
    }) || null;
  }

  function controlDisabled(control) {
    if (!control) return true;
    if (control.disabled) return true;
    if (upper(control.getAttribute?.('aria-disabled') || '') === 'TRUE') return true;
    const cls = upper(typeof control.className === 'string' ? control.className : '');
    return /(?:^|\s)(DISABLED|INACTIVE)(?:\s|$)/.test(cls);
  }

  function waitForValidatedMonthChange(fromKey, timeoutMs = 9000) {
    return new Promise(resolve => {
      const started = Date.now();
      const tick = () => {
        try {
          const month = pageMonth();
          const key = monthKey(month);
          if (key && key !== fromKey) {
            const built = build();
            const checked = validation(built);
            if (checked.isValid && checked.month === key) {
              resolve({ ok: true, key, month, built });
              return;
            }
          }
        } catch (_) {}

        if (Date.now() - started >= timeoutMs) {
          resolve({ ok: false, key: monthKey(pageMonth()), month: pageMonth(), built: null });
          return;
        }
        setTimeout(tick, 250);
      };
      setTimeout(tick, 180);
    });
  }

  async function moveOneMonth(direction, fromKey) {
    const control = switchMonthButton(direction);
    if (controlDisabled(control)) return { ok: false, reason: 'earliest', key: fromKey };
    try { control.click(); } catch (_) { return { ok: false, reason: 'click failed', key: fromKey }; }
    const moved = await waitForValidatedMonthChange(fromKey);
    if (!moved.ok) return { ...moved, reason: 'no validated month' };
    return moved;
  }

  async function backfillCrewHistory() {
    if (historyBackfillRunning) {
      historyBackfillMessage({ state: 'progress', monthLabel: pageMonth()?.label || '', scanned: 0 });
      return false;
    }

    const initialBuilt = build();
    const initialValidation = validation(initialBuilt);
    const initialMonth = pageMonth();
    const originalKey = monthKey(initialMonth);

    if (!initialValidation.isValid || !originalKey) {
      historyBackfillMessage({ state: 'error', message: 'Open a valid RAIDO monthly roster before starting crew-history backfill.' });
      return false;
    }

    historyBackfillRunning = true;
    let scanned = 1;
    let currentKey = originalKey;
    let reason = 'earliest';
    const maxMonths = 60;

    historyBackfillMessage({
      state: 'started',
      month: originalKey,
      monthLabel: initialMonth?.label || originalKey,
      scanned
    });

    // Ensure the starting month is indexed through the normal validated bridge.
    post(initialBuilt);

    try {
      while (scanned < maxMonths) {
        const previous = switchMonthButton('Previous');
        if (controlDisabled(previous)) {
          reason = 'earliest';
          break;
        }

        const moved = await moveOneMonth('Previous', currentKey);
        if (!moved.ok) {
          reason = moved.reason || 'earliest';
          // The page may have changed to an empty/unvalidated older month.
          currentKey = monthKey(pageMonth()) || currentKey;
          break;
        }

        currentKey = moved.key;
        scanned += 1;
        post(moved.built);
        historyBackfillMessage({
          state: 'progress',
          month: moved.key,
          monthLabel: moved.month?.label || moved.key,
          scanned
        });

        // Give RAIDO a short idle interval between month loads.
        await new Promise(resolve => setTimeout(resolve, 180));
      }

      if (scanned >= maxMonths) reason = 'limit';

      // Always attempt to restore the exact month from which the user started.
      let actualKey = monthKey(pageMonth()) || currentKey;
      if (actualKey !== originalKey) {
        historyBackfillMessage({ state: 'restoring', month: actualKey, scanned });
      }

      let restoreSteps = 0;
      while (actualKey && actualKey !== originalKey && restoreSteps < maxMonths + 3) {
        const next = switchMonthButton('Next');
        if (controlDisabled(next)) break;
        const moved = await moveOneMonth('Next', actualKey);
        restoreSteps += 1;
        if (!moved.ok) {
          actualKey = monthKey(pageMonth()) || actualKey;
          break;
        }
        actualKey = moved.key;
      }

      const restored = actualKey === originalKey;
      if (restored) {
        try {
          const restoredBuilt = build();
          if (validation(restoredBuilt).isValid) post(restoredBuilt);
        } catch (_) {}
      }

      historyBackfillMessage({
        state: 'complete',
        month: originalKey,
        monthLabel: initialMonth?.label || originalKey,
        scanned,
        restored,
        reason
      });
      return restored;
    } catch (error) {
      historyBackfillMessage({ state: 'error', message: `History scan failed: ${String(error)}` });
      return false;
    } finally {
      historyBackfillRunning = false;
    }
  }

'''
js = replace_once(
    js,
    '''  window.RAIDOPlus = {\n''',
    backfill_js + '''  window.RAIDOPlus = {\n''',
    "history backfill JS"
)

# Export the method without changing any existing parser/extractor export.
js = replace_once(
    js,
    '''    diagnostics\n  };\n''',
    '''    diagnostics,\n    backfillCrewHistory\n  };\n''',
    "history backfill export"
)
JS.write_text(js)


pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 14;", "CURRENT_PROJECT_VERSION = 15;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.1;", "MARKETING_VERSION = 2.11.2;")
PBX.write_text(pbx)

print("V2.11.2 automatic RAIDO crew-history backfill applied")
