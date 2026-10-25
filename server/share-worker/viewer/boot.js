// Runs before the first paint, as a blocking script in <head> (the page's
// CSP forbids inline scripts). It applies the reader's saved layout so the
// page never shifts, and starts fetching the encrypted document at once,
// before the larger scripts load. main.js picks up both. The same idea as
// Linear's boot script, which reads its saved layout from localStorage.
(() => {
  const root = document.documentElement;
  const stored = (key) => {
    try { return localStorage.getItem(key); } catch { return null; }
  };
  // Keep in step with TEXT_SIZES in main.js.
  const sizes = [13, 15, 17, 19, 22];
  const size = sizes[Number(stored("mdp.textSize"))];
  if (size) root.style.setProperty("--reader-size", `${size}px`);
  root.dataset.width = stored("mdp.width") === "full" ? "full" : "fixed";
  root.dataset.contents = stored("mdp.contents") === "hidden" ? "hidden" : "shown";

  // Slow loads: "Loading…" joins the mark after 8 s, as in Linear.
  setTimeout(() => {
    if (!root.dataset.loaded) root.classList.add("slow");
  }, 8000);

  // A share id is 16 bytes of base64url. Password links wait for main.js.
  const id = /^\/s\/([A-Za-z0-9_-]{22})\/?$/.exec(location.pathname)?.[1];
  if (id && location.hash.length > 1 && !location.hash.startsWith("#p.")) {
    window.mdpEnvelope = fetch(`/shares/${id}`, { cache: "no-store", referrerPolicy: "no-referrer" });
    window.mdpEnvelope.catch(() => {}); // main.js reports the failure
  }
})();
