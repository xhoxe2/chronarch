// Runs bridge/worker.js under Node with Gemini stubbed out, for test_bridge.py.
// stdin:  { env, gemini: {status, body}, requests: [{method, path, headers, body}] }
// stdout: [{ status, text, geminiCalls: [{url, key}] }]
import worker from "../bridge/worker.js";

let input = "";
for await (const chunk of process.stdin) input += chunk;
const { env, gemini, requests } = JSON.parse(input);
// In-memory stand-in for the QUOTA KV namespace, if the test asks for one.
const kv = {};
if (env.QUOTA_START !== undefined) {
  kv["count:" + new Date().toISOString().slice(0, 10)] = String(env.QUOTA_START);
  env.QUOTA = { get: async (k) => kv[k] ?? null, put: async (k, v) => { kv[k] = v; } };
}

const out = [];
for (const r of requests) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, key: init.headers["x-goog-api-key"], body: JSON.parse(init.body) });
    return new Response(JSON.stringify(gemini.body), { status: gemini.status });
  };
  const req = new Request("https://bridge.test" + r.path, {
    method: r.method,
    headers: r.headers,
    body: r.method === "GET" ? undefined : r.body,
  });
  const res = await worker.fetch(req, env);
  out.push({ status: res.status, text: await res.text(), geminiCalls: calls });
}
console.log(JSON.stringify({ out, kv }));
