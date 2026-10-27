// The app asks for an envelope with this Accept header. A browser that opens
// /shares/<id> as a link cannot send it, so the route is no file host: the
// bytes reach the app, and readers in a browser use /s/<id>.
// Its own module: `wrangler dev` rejects a Worker entry that exports a string.
export const ENVELOPE_TYPE = "application/vnd.md-preview.envelope";
