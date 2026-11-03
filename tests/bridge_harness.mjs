// Runs bridge/worker.js under Node with Gemini stubbed out, for test_bridge.py.
// stdin:  { env, gemini: {status, body}, requests: [{method, path, headers, body}] }
// stdout: [{ status, text, geminiCalls: [{url, key}] }]
import worker from "../bridge/worker.js";

let input = "";
for await (const chunk of process.stdin) input += chunk;
const { env, gemini, requests } = JSON.parse(input);

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
console.log(JSON.stringify(out));
