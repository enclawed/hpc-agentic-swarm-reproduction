// A logging proxy in front of the model server. Every agent reaches the model
// through it, so the record shows that each decision came from the model:
// which agent asked, which tools it was offered, which tool calls the model
// returned, and the tokens and time each request took.
//
//   node model-log.mjs LISTEN_PORT http://127.0.0.1:MODEL_PORT LOG.jsonl
import fs from "node:fs";
import http from "node:http";

const [, , listen, target, logPath] = process.argv;
const log = fs.createWriteStream(logPath, { flags: "a" });

http
  .createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      let request = null;
      try {
        request = JSON.parse(body.toString());
      } catch {
        // not JSON (model listing and the like)
      }
      const t0 = Date.now();
      const up = http.request(
        target + req.url,
        { method: req.method, headers: { ...req.headers, host: new URL(target).host } },
        (r) => {
          res.writeHead(r.statusCode ?? 502, r.headers);
          const out = [];
          r.on("data", (c) => {
            out.push(c);
            res.write(c);
          });
          r.on("end", () => {
            res.end();
            if (req.url !== "/api/chat") {
              return;
            }
            const toolCalls = [];
            let last = {};
            let text = "";
            for (const line of Buffer.concat(out).toString().split("\n")) {
              try {
                const m = JSON.parse(line);
                for (const tc of m.message?.tool_calls ?? []) {
                  toolCalls.push(tc.function);
                }
                text += m.message?.content ?? "";
                last = m;
              } catch {
                // partial line
              }
            }
            log.write(
              JSON.stringify({
                t0,
                t1: Date.now(),
                // Each agent's model configuration sends its rank in a header.
                agent: req.headers["x-enclawed-agent"] ?? null,
                model: request?.model,
                tools: (request?.tools ?? []).length,
                messages: request?.messages?.length,
                toolCalls,
                text: text.slice(0, 2000),
                promptTokens: last.prompt_eval_count,
                outputTokens: last.eval_count,
                modelMs: last.total_duration ? Math.round(last.total_duration / 1e6) : null,
              }) + "\n",
            );
          });
        },
      );
      up.on("error", (e) => {
        res.writeHead(502);
        res.end(String(e));
      });
      up.end(body);
    });
  })
  .listen(Number(listen), "127.0.0.1");
