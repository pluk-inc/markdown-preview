// The viewer page's Content Security Policy, shared by the Worker and the
// static-asset headers. Only same-origin scripts run, so nothing else can
// read the key in the URL fragment; remote images are blocked, so opening a
// link does not tell a third party who read it. KaTeX sets inline style
// attributes, and its fonts are data: URLs inside katex.min.css.
export const VIEWER_CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "style-src-attr 'unsafe-inline'",
  "img-src 'self' blob: data:",
  "font-src data:",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");
