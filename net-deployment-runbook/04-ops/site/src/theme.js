// @flow strict

declare var window: any;
declare var document: any;

const THEME_KEY = "gdc-theme";

function storedTheme(): string {
  try {
    const value = String(window.localStorage.getItem(THEME_KEY) || "");
    return value === "light" || value === "dark" ? value : "";
  } catch {
    return "";
  }
}

function activeTheme(): string {
  const chosen = String(document.documentElement.dataset.theme || "");
  if (chosen === "light" || chosen === "dark") return chosen;
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function describeToggle(button: any): void {
  const dark = activeTheme() === "dark";
  button.setAttribute("aria-pressed", String(dark));
  button.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme");
  button.title = dark ? "Light theme" : "Dark theme";
}

// Runs in the document head: a stored choice applies before the first paint.
// Without one the stylesheet follows the system setting.
(function applyStoredTheme(): void {
  const stored = storedTheme();
  if (stored) document.documentElement.dataset.theme = stored;
  document.addEventListener("DOMContentLoaded", () => {
    const button = document.getElementById("theme-toggle");
    if (!button) return;
    describeToggle(button);
    button.addEventListener("click", () => {
      const next = activeTheme() === "dark" ? "light" : "dark";
      document.documentElement.dataset.theme = next;
      try {
        window.localStorage.setItem(THEME_KEY, next);
      } catch {}
      describeToggle(button);
    });
  });
})();
