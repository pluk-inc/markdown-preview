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

const page = {
  title: document.getElementById("doc-title"),
  open: document.getElementById("open-in-app"),
  download: document.getElementById("download"),
  notice: document.getElementById("notice"),
  status: document.getElementById("status"),
  article: document.querySelector("article.markdown-body"),
};

// The page's own text; the shared document keeps its own language.
function localizePage() {
  document.documentElement.lang = language;
  document.title = `${text.untitled} · Markdown Preview`;
  for (const element of document.querySelectorAll("[data-l10n]")) {
    element.textContent = text[element.dataset.l10n];
  }
  if (language === "fa") {
    for (const element of document.querySelectorAll(".mdp-share-bar, .mdp-share-notice, .mdp-share-status, .mdp-share-footer")) {
      element.setAttribute("dir", "rtl");
    }
  }
}

function showStatus(message) {
  page.status.textContent = message;
  page.status.hidden = false;
}

async function main() {
  const link = parseLink(location.pathname, location.hash);
  if (!link) return showStatus(text.incomplete);
  page.open.href = `md-preview://share/${link.id}#${link.fragment}`;
  if (link.hasPassword) return showStatus(text.password);

  let envelope;
  try {
    const response = await fetch(`/shares/${link.id}`, { cache: "no-store", referrerPolicy: "no-referrer" });
    if (response.status === 404) return showStatus(text.gone);
    if (!response.ok) return showStatus(text.unavailable);
    envelope = new Uint8Array(await response.arrayBuffer());
  } catch {
    return showStatus(text.unavailable);
  }

  let payload;
  try {
    payload = decodePayload(await openEnvelope(envelope, link.key, null));
  } catch (error) {
    if (error instanceof ShareError && error.code === "password") return showStatus(text.password);
    return showStatus(text.damaged);
  }
  render(payload);
}

function render(payload) {
  const title = displayTitle(payload.title) || text.untitled;
  document.title = `${title} · Markdown Preview`;
  page.title.textContent = title;

  const markdown = new Blob([payload.markdown], { type: "text/markdown;charset=utf-8" });
  page.download.href = URL.createObjectURL(markdown);
  page.download.download = /\.(md|markdown)$/i.test(title) ? title : `${title}.md`;
  page.download.hidden = false;

  page.article.innerHTML = DOMPurify.sanitize(payload.html, SANITIZE_CONFIG);
  const blockedImages = attachImages(payload.assets);
  if (blockedImages > 0) {
    page.notice.textContent = blockedImages === 1
      ? text.hiddenImageOne
      : text.hiddenImageMany.replace("{count}", String(blockedImages));
    page.notice.hidden = false;
  }

  for (const element of page.article.querySelectorAll(".math")) {
    MdpRenderers.renderMathElement(element, element.textContent, element.classList.contains("math-display"));
  }
  MdpRenderers.highlightAll();
}

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
main();
