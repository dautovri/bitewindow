// Deployed entry: the app API (index.ts) and the web pages' RPC entrypoint (web.ts). Kept
// apart so index.ts still loads under `node --test`, which has no `cloudflare:workers`.
export { default } from "./index.ts";
export { WebForecast } from "./web.ts";
