// The share link web viewer: reads the envelope the Worker streamed into the
// page, decrypts it with the key from the URL fragment, and shows the document with the app's own
// stylesheet and renderers. The key never leaves this page; the server only
// ever sees the encrypted envelope. docs/share-link-plan.md §5.

import { ShareError, openEnvelope, parseLink } from "./share-crypto.js";
import { assetPathForSource, base64Bytes, decodePayload, displayTitle, isWebSource } from "./payload.js";
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
    // Only the diagram HUD's buttons stay (see the afterSanitizeAttributes hook).
    "button",
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
  resizer: byId("contents-resizer"),
  resizerIndicator: byId("resizer-indicator"),
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

/** Shows why the document cannot be shown. "Open in Markdown Preview"
 * stays: it opens the link in the app (or, for a link without a key, the
 * website), so the reader can still reach the app from here. */
function showStatus(message) {
  page.statusText.textContent = message;
  page.status.hidden = false;
  page.crumbSeparator.setAttribute("hidden", "");
  page.download.hidden = true;
  document.documentElement.dataset.loaded = "error";
}

// MARK: - Reading options, remembered per browser

const TEXT_SIZES = window.mdpTextSize.sizes;

function stored(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}

function store(key, value) {
  try { localStorage.setItem(key, value); } catch {}
}

// boot.js has already applied these before the first paint.
const reading = {
  size: window.mdpTextSize.size,
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

/** Fades the rail's top or bottom edge while more of the list is past it. */
function updateContentsFade() {
  const rail = page.contents;
  rail.classList.toggle("fade-top", rail.scrollTop > 0);
  rail.classList.toggle("fade-bottom", rail.scrollTop + rail.clientHeight < rail.scrollHeight - 1);
}

page.contents.addEventListener("scroll", updateContentsFade, { passive: true });
window.addEventListener("resize", updateContentsFade);

// The rail's width: dragged at its edge or set with the arrow keys on it,
// remembered per browser; a double-click or Enter on the edge goes back to
// viewer.css's default. boot.js applied the saved width before the first
// paint.

const clampRailWidth = (width) => Math.round(Math.min(Math.max(width, window.mdpRail.min), window.mdpRail.max));

/** The rail's width beside the page. It is read from --rail-width, not the
 * layout, because a narrow window shows the rail as a wider drawer. */
const railWidth = () => parseFloat(getComputedStyle(page.contents).getPropertyValue("--rail-width"));

/** Saves the rail's width (null for the default) and applies it page-wide. */
function saveRailWidth(width) {
  page.contents.style.removeProperty("--rail-width");
  if (width === null) document.documentElement.style.removeProperty("--rail-width");
  else document.documentElement.style.setProperty("--rail-width", `${width}px`);
  store("mdp.railWidth", width === null ? "" : String(width));
  updateResizerValue();
  updateContentsFade();
}

/** The separator's value for assistive technology: the rail's width. */
function updateResizerValue() {
  page.resizer.setAttribute("aria-valuemin", String(window.mdpRail.min));
  page.resizer.setAttribute("aria-valuemax", String(window.mdpRail.max));
  page.resizer.setAttribute("aria-valuenow", String(railWidth()));
}

page.resizer.addEventListener("pointerdown", (event) => {
  // One drag at a time: a second finger on the edge does nothing.
  if (event.button !== 0 || document.documentElement.classList.contains("resizing")) return;
  event.preventDefault();
  const pointer = event.pointerId;
  const startX = event.clientX;
  const startWidth = railWidth();
  let width = startWidth;
  // Only the rail reads the width, so a drag restyles the rail alone.
  const drag = (move) => {
    if (move.pointerId !== pointer) return;
    width = clampRailWidth(startWidth + move.clientX - startX);
    page.contents.style.setProperty("--rail-width", `${width}px`);
  };
  const end = (lost) => {
    if (lost.pointerId !== pointer) return;
    page.resizer.removeEventListener("pointermove", drag);
    page.resizer.removeEventListener("lostpointercapture", end);
    document.documentElement.classList.remove("resizing");
    saveRailWidth(width);
  };
  page.resizer.setPointerCapture(pointer);
  page.resizer.addEventListener("pointermove", drag);
  page.resizer.addEventListener("lostpointercapture", end);
  document.documentElement.classList.add("resizing");
});

page.resizer.addEventListener("dblclick", () => saveRailWidth(null));

page.resizer.addEventListener("keydown", (event) => {
  const step = event.shiftKey ? 40 : 10;
  const width = railWidth();
  const next = {
    ArrowLeft: width - step,
    ArrowRight: width + step,
    Home: window.mdpRail.min,
    End: window.mdpRail.max,
  }[event.key];
  if (event.key === "Enter") saveRailWidth(null);
  else if (next !== undefined) saveRailWidth(clampRailWidth(next));
  else return;
  event.preventDefault();
});

updateResizerValue();

// The darker stretch of the edge's line follows the pointer, once a frame:
// centered on it, and held at the track's ends.
let resizerPointerY;
function placeResizerIndicator() {
  const track = page.resizerIndicator.parentElement.getBoundingClientRect();
  const offset = Math.min(Math.max(resizerPointerY - track.top, 0), track.height) - track.height / 2;
  page.resizerIndicator.style.transform = `translate3d(0, ${offset}px, 0)`;
  resizerPointerY = undefined;
}
page.resizer.addEventListener("pointermove", (event) => {
  if (resizerPointerY === undefined) requestAnimationFrame(placeResizerIndicator);
  resizerPointerY = event.clientY;
});

/**
 * Diagrams, drawn as the app draws them: its wiring (zoom, Fill width, the
 * HUD) on Pele, each as it nears the screen, and all at once to print.
 * Without Pele the figures show their source, with its line breaks.
 */
function drawDiagrams(figures) {
  if (!figures.length) return;
  if (!window.pele) {
    figures.forEach((figure) => figure.classList.add("mermaid-error"));
    return;
  }
  // The app's words in the reader's language; the HUD in the HTML came in
  // the author's.
  const t = MdpRenderers.diagramStrings[language] ?? MdpRenderers.diagramStrings.en;
  const hudLabels = { out: t.zoomOut, in: t.zoomIn, reset: t.resetZoom, width: t.fillWidth };
  for (const button of page.article.querySelectorAll(".mermaid-hud button[data-mm-act]")) {
    const label = hudLabels[button.dataset.mmAct];
    if (!label) continue;
    button.setAttribute("aria-label", label);
    if (button.hasAttribute("title")) button.title = label;
  }
  const diagrams = MdpRenderers.mermaidWiring(t);
  diagrams.bootstrap();
  // Print each whole diagram: draw any not drawn yet, and set aside the
  // reader's zoom and pan, which would crop it, until printing ends.
  const views = new Map();
  window.addEventListener("beforeprint", () => {
    diagrams.renderAll();
    for (const node of page.article.querySelectorAll(".mermaid-figure .mermaid")) {
      views.set(node, node.style.transform);
      node.style.transform = "";
    }
  });
  window.addEventListener("afterprint", () => {
    for (const [node, transform] of views) node.style.transform = transform;
    views.clear();
  });
}

/** Lists the document's h1–h3. The rail stays in place without them, so
 * the layout never moves once the document arrives. */
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
  const scroller = document.querySelector(".page");
  let pending = false;
  const markCurrent = () => {
    pending = false;
    let current = 0;
    // The reading area's top: the sheet scrolls on a desktop, the page on a phone.
    const top = Math.max(scroller.getBoundingClientRect().top, 0) + 60;
    headings.forEach((heading, index) => {
      if (heading.getBoundingClientRect().top < top) current = index;
    });
    buttons.forEach((button, index) => button.classList.toggle("current", index === current));
  };
  const onScroll = () => {
    if (!pending) { pending = true; requestAnimationFrame(markCurrent); }
  };
  scroller.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("scroll", onScroll, { passive: true });
  markCurrent();
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

async function main() {
  const link = parseLink(location.pathname, location.hash);
  if (!link) return showStatus(text.incomplete);
  if (touchDevice.matches) offerMacApp();
  else page.open.href = `md-preview://share/${link.id}#${link.fragment}`;
  if (link.hasPassword) return showStatus(text.password);

  const envelope = pageEnvelope();
  if (envelope.status === "not_found") return showStatus(text.gone);
  if (!envelope.bytes) return showStatus(text.unavailable);

  let payload;
  try {
    payload = decodePayload(await openEnvelope(envelope.bytes, link.key, null));
  } catch (error) {
    if (error instanceof ShareError && error.code === "password") return showStatus(text.password);
    return showStatus(text.damaged);
  }
  await render(payload);
}

/**
 * The envelope the Worker streamed into the page (#mdp-envelope), so it
 * needs no second request: `{ bytes }`, or `{ status }` ("not_found",
 * "unavailable") when there is none to show.
 */
function pageEnvelope() {
  const block = document.getElementById("mdp-envelope");
  if (!block) return { status: "unavailable" };
  block.remove();
  const { status } = block.dataset;
  if (status !== "ok") return { status };
  try {
    return { bytes: base64Bytes(block.textContent) };
  } catch {
    return { status: "unavailable" };
  }
}

/** Loads a vendor script or stylesheet once, only when a document needs it. */
const loaded = new Map();
function loadVendor(file) {
  if (!loaded.has(file)) {
    loaded.set(file, new Promise((resolve) => {
      const isStyle = file.endsWith(".css");
      const element = document.createElement(isStyle ? "link" : "script");
      // File name to content-hashed URL, written in by viewer/build.mjs.
      const url = VENDOR_URLS[file];
      if (isStyle) { element.rel = "stylesheet"; element.href = url; }
      else element.src = url;
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
  decorateCodeBlocks();
  const blockedImages = attachImages(payload.assets);
  if (blockedImages > 0) {
    page.notice.textContent = blockedImages === 1
      ? text.hiddenImageOne
      : text.hiddenImageMany.replace("{count}", String(blockedImages));
    page.notice.hidden = false;
  }

  // Highlighting, math, and diagrams load only for documents that use them.
  const math = page.article.querySelectorAll(".math");
  const diagrams = page.article.querySelectorAll(".mermaid-figure");
  await Promise.all([
    math.length && loadVendor("katex.min.css"),
    math.length && loadVendor("katex.min.js"),
    page.article.querySelector("pre > code") && loadVendor("highlight.min.js"),
    diagrams.length && loadVendor("pele.global.js"),
  ]);
  for (const element of math) {
    MdpRenderers.renderMathElement(element, element.textContent, element.classList.contains("math-display"));
  }
  MdpRenderers.highlightAll();
  drawDiagrams(diagrams);
  buildContents();
  document.documentElement.dataset.loaded = "document";
  applyReading();
}

// MARK: - Code blocks

// The app's code block header (MarkdownHTML+HostBridge.swift): the
// language, then Wrap and Copy, with the app's class names and icons, so
// the app's stylesheet draws it.
const codeIcon = (kind) => '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ({
  copy: '<rect x="4" y="8" width="12" height="13" rx="3"/><path d="M8 8V6a3 3 0 0 1 3-3h6a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-1"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  wrap: '<path d="M4 6h16M4 11h12a4 4 0 0 1 0 8h-5m3-3-3 3 3 3M4 16h3"/>',
  unwrap: '<path d="M4 6h16M4 12h16m-4-4 4 4-4 4M4 18h7"/>',
})[kind] + "</svg>";

function codeAction(className, icon, label) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `md-code-action ${className}`;
  button.innerHTML = codeIcon(icon);
  button.title = label;
  button.setAttribute("aria-label", label);
  return button;
}

function decorateCodeBlocks() {
  for (const code of page.article.querySelectorAll("pre > code")) {
    const pre = code.parentElement;
    const wrap = document.createElement("div");
    wrap.className = "md-code-wrap";
    pre.before(wrap);
    const header = document.createElement("div");
    header.className = "md-code-header";
    const language = document.createElement("span");
    language.className = "md-code-language";
    language.textContent = pre.dataset.codeLanguage || "text";
    const toggle = codeAction("md-code-toggle-wrap", "wrap", text.wrapCode);
    toggle.setAttribute("aria-pressed", "false");
    header.append(language, toggle, codeAction("md-code-copy", "copy", text.copyCode));
    wrap.append(header, pre);
  }
}

page.article.addEventListener("click", async (event) => {
  const toggle = event.target.closest(".md-code-toggle-wrap");
  if (toggle) {
    const wrapped = toggle.closest(".md-code-wrap").classList.toggle("is-wrapped");
    // A toggle keeps one label ("Wrap code") and reports its state with
    // aria-pressed; only the tooltip names the next action.
    toggle.setAttribute("aria-pressed", String(wrapped));
    toggle.title = wrapped ? text.unwrapCode : text.wrapCode;
    toggle.innerHTML = codeIcon(wrapped ? "unwrap" : "wrap");
    return;
  }
  const button = event.target.closest(".md-code-copy");
  if (!button) return;
  try {
    await navigator.clipboard.writeText(button.closest(".md-code-wrap").querySelector("pre > code").textContent);
  } catch {
    return; // As in the app: no check mark, and the button stays as it was.
  }
  button.innerHTML = codeIcon("check");
  button.title = text.codeCopied;
  button.setAttribute("aria-label", text.codeCopied);
  clearTimeout(button.copiedTimer);
  button.copiedTimer = setTimeout(() => {
    button.innerHTML = codeIcon("copy");
    button.title = text.copyCode;
    button.setAttribute("aria-label", text.copyCode);
  }, 1100);
});

// Copying whole blocks puts their Markdown source on the clipboard, as the
// app does; a selection inside one block copies as text.
window.addEventListener("copy", (event) => {
  const selection = getSelection();
  if (!window.MdPreview || !event.clipboardData) return;
  const markdown = MdpRenderers.markdownForSelection(selection);
  if (markdown === null) return;
  const html = document.createElement("div");
  for (let i = 0; i < selection.rangeCount; i++) html.append(selection.getRangeAt(i).cloneContents());
  // The code header (language, buttons) is page chrome, not document.
  html.querySelectorAll(".md-code-header").forEach((header) => header.remove());
  event.clipboardData.setData("text/plain", markdown);
  event.clipboardData.setData("text/html", html.innerHTML);
  event.preventDefault();
});

/** Points images at the share's own files; returns how many remote images were hidden. */
function attachImages(assets) {
  const byPath = new Map(assets.map((asset) => [asset.path, asset]));
  // Images from the web, downloaded by the app when it made the link.
  const bySource = new Map(assets.filter((asset) => asset.source).map((asset) => [asset.source, asset.path]));
  const urls = new Map();
  const urlFor = (path) => {
    const asset = byPath.get(path);
    if (asset && !urls.has(path)) urls.set(path, URL.createObjectURL(new Blob([asset.data], { type: asset.type })));
    return urls.get(path);
  };
  let blocked = 0;
  for (const image of page.article.querySelectorAll("img")) {
    const source = image.getAttribute("src") ?? "";
    // Images embedded in the document travel with it and reach no server.
    if (/^data:image\//i.test(source)) continue;
    const url = urlFor(bySource.get(source) ?? assetPathForSource(source));
    if (url) {
      image.src = url;
    } else {
      // Remote images would tell their server who opened the link; the
      // page's CSP blocks them anyway, so show the description instead.
      if (isWebSource(source)) blocked += 1;
      const placeholder = document.createElement("span");
      placeholder.className = "mdp-missing-image";
      placeholder.textContent = image.alt || text.image;
      image.replaceWith(placeholder);
    }
  }
  return blocked;
}


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
const isLocalFileLink = (href) => href !== "" && !/^[a-z][a-z0-9+.-]*:/i.test(href)
  && !href.startsWith("//") && !href.startsWith("#") && !href.startsWith("?");

DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node.tagName === "A" && node.hasAttribute("href")) {
    const href = node.getAttribute("href");
    // A link to another of the author's files (notes.md, ../plan.pdf,
    // /docs/a.md: no scheme, no host, not this page) is not in the share
    // and would open a broken page here: keep its text.
    if (isLocalFileLink(href)) {
      node.removeAttribute("href");
      node.classList.add("mdp-unshared-link");
      node.title = text.linkNotShared;
    } else if (!href.startsWith("#")) {
      node.setAttribute("rel", "noopener noreferrer nofollow");
      node.setAttribute("target", "_blank");
    }
  }
  // Buttons only for the diagram HUD; its window button needs the app.
  if (node.tagName === "BUTTON"
      && (!node.closest(".mermaid-hud") || node.dataset.mmAct === "popup")) {
    node.remove();
  }
  if (node.tagName === "INPUT") {
    if (node.getAttribute("type") !== "checkbox") node.remove();
    else node.setAttribute("disabled", "");
  }
});

localizePage();
applyReading();
main();
