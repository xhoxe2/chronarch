// CHRONARCH :: Bridge (Cloudflare Worker)
// The base computer asks a question over HTTP; the bridge checks the request
// is signed with the colony's shared secret, asks Gemini and answers in plain
// ASCII (the CC font shows nothing else). API keys live only here, as Worker
// secrets, never on game computers:
//   GEMINI_KEY     free-tier Gemini API key
//   CHRONARCH_KEY  the same text as /chronarch.key on the base and turtles
//
// Request:  POST /ask   body = question (text)
//           X-TS  = os.epoch("utc") in ms,  X-Sig = hmac(secret, ts .. "\n" .. body)
// Answer:   200 + answer text, or 4xx/5xx + a short reason.
//
// ponytail: the 2-minute window stops a recorded request being replayed later,
// not within those 2 minutes. Add a seen-nonce store (KV/D1) if that matters.

const MAX_AGE_MS = 120000;
const MAX_QUESTION = 2000; // question + colony status
const MAX_ANSWER = 600;

const SYSTEM =
  "You are CHRONARCH, the AI of a colony of mining turtles in Minecraft " +
  "(CC: Tweaked, All the Mods 10 modpack). Answer in English, plain text, " +
  "no markdown, at most 3 short sentences. The message may end with a live " +
  "colony status (turtles, fuel, ore they found): base your advice on it.";

const enc = new TextEncoder();

async function hmacHex(key, text) {
  const k = await crypto.subtle.importKey("raw", enc.encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(text)));
  return [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Constant-time compare, like eq() in chronarch.lua.
function same(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Make model text safe for the CC terminal: ASCII only, no markdown.
export function ascii(s) {
  return s
    .replace(/[‘’]/g, "'").replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-").replace(/…/g, "...")
    .replace(/[*#`_]/g, "")
    .replace(/[^\x20-\x7e\n]/g, "")
    .replace(/\n{2,}/g, "\n")
    .trim()
    .slice(0, MAX_ANSWER);
}

const reply = (text, status = 200) =>
  new Response(text, { status, headers: { "content-type": "text/plain" } });

export default {
  async fetch(req, env) {
    if (req.method !== "POST" || new URL(req.url).pathname !== "/ask") {
      return reply("not found", 404);
    }
    const ts = req.headers.get("x-ts") || "";
    const sig = req.headers.get("x-sig") || "";
    const q = await req.text();
    if (!q || q.length > MAX_QUESTION) return reply("bad question", 400);

    // Same trimming as proto.loadSecret() in the game.
    const secret = (env.CHRONARCH_KEY || "").replace(/\s+$/, "");
    if (!secret || !same(await hmacHex(secret, ts + "\n" + q), sig)) {
      return reply("bad signature", 401);
    }
    if (!(Math.abs(Date.now() - Number(ts)) <= MAX_AGE_MS)) {
      return reply("request too old", 401);
    }

    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${env.MODEL}:generateContent`,
      {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": env.GEMINI_KEY },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: SYSTEM }] },
          contents: [{ role: "user", parts: [{ text: q }] }],
        }),
      });
    if (!r.ok) {
      if (r.status === 429) return reply("gemini: free limit reached, try later", 502);
      const why = await r.json().then((e) => e?.error?.message || "", () => "");
      return reply(ascii(`gemini error ${r.status} ${why}`).slice(0, 160), 502);
    }
    const data = await r.json();
    const parts = data?.candidates?.[0]?.content?.parts || [];
    return reply(ascii(parts.map((p) => p.text || "").join("")) || "(no answer)");
  },
};
