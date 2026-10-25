// Runs before the first paint, as a blocking script in <head> (the page's
// CSP forbids inline scripts). It applies the reader's saved layout so the
// page never shifts; main.js picks it up. The same idea as Linear's boot
// script, which reads its saved layout from localStorage. The encrypted
// document needs no request: the Worker streams it into the page.
(() => {
  const root = document.documentElement;
  const stored = (key) => {
    try { return localStorage.getItem(key); } catch { return null; }
  };
  // The reading sizes and the saved choice; main.js reads both from here.
  const sizes = [13, 15, 17, 19, 22];
  const saved = Number(stored("mdp.textSize") ?? 1);
  const size = Number.isInteger(saved) ? Math.min(Math.max(saved, 0), sizes.length - 1) : 1;
  window.mdpTextSize = { sizes, size };
  root.style.setProperty("--reader-size", `${sizes[size]}px`);
  root.dataset.width = stored("mdp.width") === "full" ? "full" : "fixed";
  root.dataset.contents = stored("mdp.contents") === "hidden" ? "hidden" : "shown";
  // The Contents rail's width bounds (main.js reads them here), and the
  // width the reader dragged it to; without one, viewer.css's default applies.
  const rail = { min: 180, max: 400 };
  window.mdpRail = rail;
  const railWidth = Number(stored("mdp.railWidth"));
  if (railWidth > 0) {
    root.style.setProperty("--rail-width", `${Math.min(Math.max(railWidth, rail.min), rail.max)}px`);
  }

  // Appearance, as in the app: Automatic follows the system, live. The
  // page always carries an explicit scheme, which the app's stylesheet
  // (data-mdp-color-scheme) and viewer.css both read.
  const systemDark = matchMedia("(prefers-color-scheme: dark)");
  window.mdpSetAppearance = (mode) => {
    root.dataset.appearance = mode;
    root.dataset.mdpColorScheme = mode === "automatic" ? (systemDark.matches ? "dark" : "light") : mode;
  };
  systemDark.addEventListener("change", () => window.mdpSetAppearance(root.dataset.appearance));
  const appearance = stored("mdp.appearance");
  window.mdpSetAppearance(appearance === "light" || appearance === "dark" ? appearance : "automatic");
})();
