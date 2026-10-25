// Where the Worker streams the encrypted envelope into the viewer page.
// viewer/build.mjs checks that viewer/index.html has it exactly once.
export const ENVELOPE_MARKER = "<!--mdp-envelope-->";
