// The share link web viewer: fetches the envelope, decrypts it with the key
// from the URL fragment, and shows the document with the app's own
// stylesheet and renderers. The key never leaves this page; the server only
// ever sees the encrypted envelope. docs/share-link-plan.md §5.

import { ShareError, openEnvelope, parseLink } from "./share-crypto.js";
import { assetPathForSource, decodePayload, displayTitle } from "./payload.js";
import { pickLanguage, strings } from "./strings.js";

// An explicit allowlist (never USE_PROFILES, which resets ALLOWED_ATTR):
// the HTML comes from whoever made the envelope, not necessarily the app.
const SANITIZE_CONFIG = {
  ALLOWED_TAGS: [
    "a", "abbr", "b", "blockquote", "br", "caption", "code", "col", "colgroup", "dd", "del",
    "details", "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5",
    "h6", "hr", "i", "img", "input", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "s",
    "samp", "section", "small", "span", "strong", "sub", "summary", "sup", "table", "tbody",
    "td", "tfoot", "th", "thead", "tr", "u", "ul", "var", "wbr",
  ],
  ALLOWED_ATTR: [
    "align", "alt", "aria-hidden", "aria-label", "checked", "class", "colspan", "dir",
    "disabled", "height", "href", "id", "lang", "open", "role", "rowspan", "src", "start",
    "title", "type", "width",
  ],
  ALLOW_DATA_ATTR: true,
  ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i,
};

const language = pickLanguage(navigator.languages?.length ? navigator.languages : [navigator.language]);
const text = strings(language);

const byId = (id) => document.getElementById(id);
const page = {
  title: byId("doc-title"),
  crumbSeparator: document.querySelector(".crumb-sep"),
  open: byId("open-in-app"),
  download: byId("download"),
  copy: byId("copy-link"),
  notice: byId("notice"),
  status: byId("status"),
  statusText: byId("status-text"),
  article: document.querySelector("article.markdown-body"),
  readingButton: byId("reading-button"),
  readingPanel: byId("reading-panel"),
  smaller: byId("text-smaller"),
  larger: byId("text-larger"),
  widthFixed: byId("width-fixed"),
  widthFull: byId("width-full"),
  appearance: {
    automatic: byId("appearance-automatic"),
    light: byId("appearance-light"),
    dark: byId("appearance-dark"),
  },
  toggleContents: byId("toggle-contents"),
  scrim: byId("scrim"),
  contents: byId("contents"),
  contentsList: byId("contents-list"),
  contentsEmpty: byId("contents-empty"),
  toast: byId("toast"),
};

// The page's own text; the shared document keeps its own language.
function localizePage() {
  document.documentElement.lang = language;
  document.title = `${text.untitled} · Markdown Preview`;
  for (const element of document.querySelectorAll("[data-l10n]")) {
    element.textContent = text[element.dataset.l10n];
  }
  for (const element of document.querySelectorAll("[data-l10n-label]")) {
    element.setAttribute("aria-label", text[element.dataset.l10nLabel]);
    element.title = text[element.dataset.l10nLabel];
  }
  if (language === "fa") {
    for (const element of document.querySelectorAll(".bar, .notice, .status, .contents")) {
      element.setAttribute("dir", "rtl");
    }
  }
}

/** Shows why the document cannot be shown. Only a password link keeps
 * "Open in Markdown Preview": the app can open it, but not a broken link. */
function showStatus(message, { appCanOpen = false } = {}) {
  page.statusText.textContent = message;
  page.status.hidden = false;
  page.crumbSeparator.setAttribute("hidden", "");
  page.open.hidden = !appCanOpen;
  document.documentElement.dataset.loaded = "error";
}

// MARK: - Reading options, remembered per browser

const TEXT_SIZES = [13, 15, 17, 19, 22];
const DEFAULT_SIZE = 1;

function stored(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}

function store(key, value) {
  try { localStorage.setItem(key, value); } catch {}
}

// boot.js has already applied these before the first paint.
const reading = {
  size: Math.min(Math.max(Number(stored("mdp.textSize") ?? DEFAULT_SIZE) || 0, 0), TEXT_SIZES.length - 1),
  width: document.documentElement.dataset.width === "full" ? "full" : "fixed",
  contents: document.documentElement.dataset.contents !== "hidden",
  appearance: document.documentElement.dataset.appearance ?? "automatic",
};

function applyReading() {
  const root = document.documentElement;
  root.style.setProperty("--reader-size", `${TEXT_SIZES[reading.size]}px`);
  root.dataset.width = reading.width;
  page.smaller.disabled = reading.size === 0;
  page.larger.disabled = reading.size === TEXT_SIZES.length - 1;
  page.widthFixed.setAttribute("aria-checked", String(reading.width === "fixed"));
  page.widthFull.setAttribute("aria-checked", String(reading.width === "full"));
  for (const [mode, button] of Object.entries(page.appearance)) {
    button.setAttribute("aria-checked", String(reading.appearance === mode));
  }
  window.mdpSetAppearance?.(reading.appearance);
  placeThumbs();
  root.dataset.contents = reading.contents ? "shown" : "hidden";
  updateContentsAccess();
}

// Narrow windows show the contents as a drawer over the page instead of a
// rail beside it. The drawer always starts closed and is not remembered.
const narrow = matchMedia("(max-width: 980px)");

function updateContentsAccess() {
  const shown = narrow.matches ? document.documentElement.dataset.drawer === "open" : reading.contents;
  page.contents.inert = !shown;
  page.toggleContents.setAttribute("aria-pressed", String(shown));
}

function setDrawerOpen(open) {
  document.body.classList.add("motion");
  if (open) document.documentElement.dataset.drawer = "open";
  else delete document.documentElement.dataset.drawer;
  updateContentsAccess();
}

narrow.addEventListener("change", () => setDrawerOpen(false));

function setReading(change) {
  Object.assign(reading, change);
  store("mdp.textSize", String(reading.size));
  store("mdp.width", reading.width);
  store("mdp.contents", reading.contents ? "shown" : "hidden");
  store("mdp.appearance", reading.appearance);
  applyReading();
}

/** Moves each switch's thumb under its chosen option. It slides only
 * once the panel is open, so opening the panel never animates it. */
function placeThumbs() {
  if (page.readingPanel.hidden) return;
  for (const group of page.readingPanel.querySelectorAll(".segmented")) {
    const chosen = group.querySelector('[aria-checked="true"]');
    if (!chosen) continue;
    // Layout offsets, not getBoundingClientRect: the panel is still scaling
    // in when it opens, and only the layout values ignore that transform.
    group.style.setProperty("--thumb-x", `${chosen.offsetLeft}px`);
    group.style.setProperty("--thumb-width", `${chosen.offsetWidth}px`);
  }
}

function setReadingPanelOpen(open) {
  page.readingPanel.hidden = !open;
  page.readingButton.setAttribute("aria-expanded", String(open));
  const groups = page.readingPanel.querySelectorAll(".segmented");
  groups.forEach((group) => group.classList.remove("sliding"));
  if (!open) return;
  placeThumbs();
  requestAnimationFrame(() => groups.forEach((group) => group.classList.add("sliding")));
}

page.readingButton.addEventListener("click", () => setReadingPanelOpen(page.readingPanel.hidden));
page.smaller.addEventListener("click", () => setReading({ size: reading.size - 1 }));
page.larger.addEventListener("click", () => setReading({ size: reading.size + 1 }));
page.widthFixed.addEventListener("click", () => setReading({ width: "fixed" }));
page.widthFull.addEventListener("click", () => setReading({ width: "full" }));
for (const [mode, button] of Object.entries(page.appearance)) {
  button.addEventListener("click", () => setReading({ appearance: mode }));
}
page.toggleContents.addEventListener("click", () => {
  if (narrow.matches) {
    setDrawerOpen(document.documentElement.dataset.drawer !== "open");
    return;
  }
  // Animate only what the reader does, never the first layout.
  document.body.classList.add("motion");
  setReading({ contents: !reading.contents });
});
page.scrim.addEventListener("click", () => setDrawerOpen(false));
document.addEventListener("click", (event) => {
  if (!page.readingPanel.hidden && !event.target.closest(".reading")) setReadingPanelOpen(false);
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !page.readingPanel.hidden) {
    setReadingPanelOpen(false);
    page.readingButton.focus();
  } else if (event.key === "Escape" && document.documentElement.dataset.drawer === "open") {
    setDrawerOpen(false);
    page.toggleContents.focus();
  }
  // Select All takes the document only, as the app's reader does, unless
  // the reader is typing in a field.
  const selectAll = (event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "a";
  if (selectAll && page.article.childElementCount > 0 && !event.target.closest?.("input, textarea, [contenteditable]")) {
    event.preventDefault();
    const range = document.createRange();
    range.selectNodeContents(page.article);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  }
});

// MARK: - Contents

/** Lists the document's h1–h3. The rail stays in place without them, so
 * the layout never moves once the document arrives. */
/** Fades the rail's top or bottom edge while more of the list is past it. */
function updateContentsFade() {
  const rail = page.contents;
  rail.classList.toggle("fade-top", rail.scrollTop > 0);
  rail.classList.toggle("fade-bottom", rail.scrollTop + rail.clientHeight < rail.scrollHeight - 1);
}

page.contents.addEventListener("scroll", updateContentsFade, { passive: true });
window.addEventListener("resize", updateContentsFade);

function buildContents() {
  const headings = [...page.article.querySelectorAll("h1, h2, h3")];
  if (headings.length === 0) {
    page.contentsEmpty.hidden = false;
    return;
  }
  const top = Math.min(...headings.map((heading) => Number(heading.tagName[1])));
  page.contentsList.replaceChildren(...headings.map((heading, index) => {
    if (!heading.id) heading.id = `mdp-heading-${index}`;
    const item = document.createElement("li");
    item.className = `level-${Number(heading.tagName[1]) - top + 1}`;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = heading.textContent.trim();
    button.addEventListener("click", () => {
      if (narrow.matches) setDrawerOpen(false);
      heading.scrollIntoView();
    });
    item.append(button);
    return item;
  }));

  // Marks the heading the reader is in.
  const buttons = [...page.contentsList.querySelectorAll("button")];
  const observer = new IntersectionObserver(() => {
    let current = 0;
    // The reading area's top: the sheet scrolls on a desktop, the page on a phone.
    const top = Math.max(document.querySelector(".page").getBoundingClientRect().top, 0) + 60;
    headings.forEach((heading, index) => {
      if (heading.getBoundingClientRect().top < top) current = index;
    });
    buttons.forEach((button, index) => button.classList.toggle("current", index === current));
  }, { rootMargin: "0px 0px -60% 0px" });
  headings.forEach((heading) => observer.observe(heading));
  updateContentsFade();
}

// MARK: - Copy link

let toastTimer;
function showToast(message) {
  page.toast.textContent = message;
  page.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { page.toast.hidden = true; }, 1800);
}

page.copy.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(location.href);
    showToast(text.linkCopied);
  } catch {
    showToast(text.copyFailed);
  }
});

// A page cannot tell whether the app is installed, so it opens the app by
// itself only in a browser where "Open in Markdown Preview" has already
// worked: the page lost focus right after the click. Elsewhere, Safari would
// show an error for a scheme no app handles.
const OPENS_IN_APP_KEY = "mdp.opensInApp";

function opensInApp() {
  try { return localStorage.getItem(OPENS_IN_APP_KEY) === "1"; } catch { return false; }
}

function rememberAppOpened() {
  const remember = () => {
    try { localStorage.setItem(OPENS_IN_APP_KEY, "1"); } catch {}
  };
  window.addEventListener("blur", remember, { once: true });
  setTimeout(() => window.removeEventListener("blur", remember), 3000);
}

// Phones and tablets have no app to open the share in. The button still
// names the app the document came from, and copies the link to the Mac app
// so the reader can get it on their Mac.
const touchDevice = matchMedia("(hover: none) and (pointer: coarse)");

function offerMacApp() {
  for (const label of page.open.querySelectorAll("span")) label.textContent = text.getMacApp;
  page.open.addEventListener("click", async (event) => {
    event.preventDefault();
    try {
      await navigator.clipboard.writeText(page.open.href);
      showToast(text.macAppLinkCopied);
    } catch {
      location.assign(page.open.href);
    }
  });
}

function openInAppIfRemembered() {
  if (opensInApp()) location.assign(page.open.href);
}

async function main() {
  const link = parseLink(location.pathname, location.hash);
  if (!link) return showStatus(text.incomplete);
  if (touchDevice.matches) offerMacApp();
  else {
    page.open.href = `md-preview://share/${link.id}#${link.fragment}`;
    page.open.addEventListener("click", rememberAppOpened);
  }
  if (link.hasPassword) {
    openInAppIfRemembered();
    return showStatus(text.password, { appCanOpen: true });
  }

  let envelope;
  try {
    // boot.js started this request before the larger scripts loaded.
    const response = await (window.mdpEnvelope ??
      fetch(`/shares/${link.id}`, { cache: "no-store", referrerPolicy: "no-referrer" }));
    if (response.status === 404) return showStatus(text.gone);
    if (!response.ok) return showStatus(text.unavailable);
    // Only a live share is worth the app's attention.
    openInAppIfRemembered();
    envelope = new Uint8Array(await response.arrayBuffer());
  } catch {
    return showStatus(text.unavailable);
  }

  let payload;
  try {
    payload = decodePayload(await openEnvelope(envelope, link.key, null));
  } catch (error) {
    if (error instanceof ShareError && error.code === "password") return showStatus(text.password, { appCanOpen: true });
    return showStatus(text.damaged);
  }
  await render(payload);
}

/** Loads a vendor script or stylesheet once, only when a document needs it. */
const loaded = new Map();
function loadVendor(file) {
  if (!loaded.has(file)) {
    loaded.set(file, new Promise((resolve) => {
      const isStyle = file.endsWith(".css");
      const element = document.createElement(isStyle ? "link" : "script");
      if (isStyle) { element.rel = "stylesheet"; element.href = `/s/_viewer/vendor/${file}`; }
      else element.src = `/s/_viewer/vendor/${file}`;
      element.onload = element.onerror = resolve;
      document.head.append(element);
    }));
  }
  return loaded.get(file);
}

async function render(payload) {
  const title = displayTitle(payload.title) || text.untitled;
  document.title = `${title} · Markdown Preview`;
  page.title.textContent = title;

  const markdown = new Blob([payload.markdown], { type: "text/markdown;charset=utf-8" });
  page.download.href = URL.createObjectURL(markdown);
  page.download.download = /\.(md|markdown)$/i.test(title) ? title : `${title}.md`;

  // The app's copy-as-Markdown code reads the source from here.
  window.MdPreview = { source: payload.markdown };
  page.article.innerHTML = DOMPurify.sanitize(payload.html, SANITIZE_CONFIG);
  const blockedImages = attachImages(payload.assets);
  if (blockedImages > 0) {
    page.notice.textContent = blockedImages === 1
      ? text.hiddenImageOne
      : text.hiddenImageMany.replace("{count}", String(blockedImages));
    page.notice.hidden = false;
  }

  // Highlighting and math load only for documents that use them.
  const math = page.article.querySelectorAll(".math");
  await Promise.all([
    math.length && loadVendor("katex.min.css"),
    math.length && loadVendor("katex.min.js"),
    page.article.querySelector("pre > code") && loadVendor("highlight.min.js"),
  ]);
  for (const element of math) {
    MdpRenderers.renderMathElement(element, element.textContent, element.classList.contains("math-display"));
  }
  MdpRenderers.highlightAll();
  buildContents();
  document.documentElement.dataset.loaded = "document";
  applyReading();
}

// Copying whole blocks puts their Markdown source on the clipboard, as the
// app does; a selection inside one block copies as text.
window.addEventListener("copy", (event) => {
  const selection = getSelection();
  if (!window.MdPreview || !event.clipboardData) return;
  const markdown = MdpRenderers.markdownForSelection(selection);
  if (markdown === null) return;
  const html = document.createElement("div");
  for (let i = 0; i < selection.rangeCount; i++) html.append(selection.getRangeAt(i).cloneContents());
  event.clipboardData.setData("text/plain", markdown);
  event.clipboardData.setData("text/html", html.innerHTML);
  event.preventDefault();
});

/** Points images at the share's own files; returns how many remote images were hidden. */
function attachImages(assets) {
  const urls = new Map(assets.map((asset) =>
    [asset.path, URL.createObjectURL(new Blob([asset.data], { type: asset.type }))]));
  let blocked = 0;
  for (const image of page.article.querySelectorAll("img")) {
    const source = image.getAttribute("src") ?? "";
    const url = urls.get(assetPathForSource(source));
    if (url) {
      image.src = url;
    } else {
      // Remote images would tell their server who opened the link; the
      // page's CSP blocks them anyway, so show the description instead.
      if (/^https?:/i.test(source)) blocked += 1;
      const placeholder = document.createElement("span");
      placeholder.className = "mdp-missing-image";
      placeholder.textContent = image.alt || text.image;
      image.replaceWith(placeholder);
    }
  }
  return blocked;
}

// The app's renderers log timings through this; the page has no use for them.
globalThis.MdPreviewPerf = { log() {}, now: () => performance.now() };

// The URL fragment holds the key, so in-page links (footnotes, headings)
// scroll to their target instead of replacing the fragment.
page.article.addEventListener("click", (event) => {
  const link = event.target.closest?.('a[href^="#"]');
  if (!link) return;
  event.preventDefault();
  let id = link.getAttribute("href").slice(1);
  try { id = decodeURIComponent(id); } catch {}
  // `#` and `#top` scroll to the top, as browsers do.
  const target = document.getElementById(id)
    ?? (id === "" || id.toLowerCase() === "top" ? document.documentElement : null);
  target?.scrollIntoView();
});

// Links leave the page without the key: no referrer, no opener.
DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node.tagName === "A" && node.hasAttribute("href")) {
    const href = node.getAttribute("href");
    if (!href.startsWith("#")) {
      node.setAttribute("rel", "noopener noreferrer nofollow");
      node.setAttribute("target", "_blank");
    }
  }
  if (node.tagName === "INPUT") {
    if (node.getAttribute("type") !== "checkbox") node.remove();
    else node.setAttribute("disabled", "");
  }
});

localizePage();
applyReading();
main();
