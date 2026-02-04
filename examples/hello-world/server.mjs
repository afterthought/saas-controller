import { createServer } from "node:http";

const port = parseInt(process.env.PORT || "3000", 10);

const server = createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Hello World\n");
});

server.listen(port, "127.0.0.1", () => {
  console.log(`hello-world listening on http://127.0.0.1:${port}`);
});
