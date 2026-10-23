// Types for `env` and `exports` from "cloudflare:workers" in the tests.
type ShareWorkerEnv = import("../src/index").Env;

declare namespace Cloudflare {
  interface Env extends ShareWorkerEnv {}
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
}
