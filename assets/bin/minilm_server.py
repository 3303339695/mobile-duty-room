#!/usr/bin/env python3
import argparse
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MODEL_NAME = "paraphrase-multilingual-MiniLM-L12-v2"
MAX_BODY = 8 * 1024 * 1024


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--api-key", default="local-minilm")
    return parser.parse_args()


os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

from sentence_transformers import SentenceTransformer  # noqa: E402


class EmbeddingHandler(BaseHTTPRequestHandler):
    server_version = "ZhibanshiMiniLM/1.0"

    def log_message(self, fmt, *args):
        print("[MiniLM] " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self):
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {self.server.api_key}"

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            self.send_json(
                200,
                {
                    "status": "ok",
                    "model": MODEL_NAME,
                    "dimensions": 384,
                    "offline": True,
                },
            )
            return
        if not self.authorized():
            self.send_json(401, {"error": {"message": "invalid api key"}})
            return
        if self.path.rstrip("/") == "/v1/models":
            self.send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": MODEL_NAME,
                            "object": "model",
                            "created": 0,
                            "owned_by": "local",
                        }
                    ],
                },
            )
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/embeddings":
            self.send_json(404, {"error": {"message": "not found"}})
            return
        if not self.authorized():
            self.send_json(401, {"error": {"message": "invalid api key"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                raise ValueError("invalid body size")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            inputs = payload.get("input")
            if isinstance(inputs, str):
                texts = [inputs]
            elif isinstance(inputs, list) and all(isinstance(item, str) for item in inputs):
                texts = inputs
            else:
                raise ValueError("input must be a string or list of strings")
            vectors = self.server.model.encode(
                texts,
                normalize_embeddings=True,
                show_progress_bar=False,
            )
            data = []
            for index, vector in enumerate(vectors):
                data.append(
                    {
                        "object": "embedding",
                        "embedding": [round(float(value), 8) for value in vector],
                        "index": index,
                    }
                )
            tokens = sum(max(1, len(text.encode("utf-8")) // 4) for text in texts)
            self.send_json(
                200,
                {
                    "object": "list",
                    "data": data,
                    "model": payload.get("model") or MODEL_NAME,
                    "usage": {
                        "prompt_tokens": tokens,
                        "total_tokens": tokens,
                    },
                },
            )
        except Exception as exc:
            self.send_json(400, {"error": {"message": str(exc), "type": "invalid_request_error"}})


def main():
    args = parse_args()
    print("[MiniLM] loading model in offline mode", flush=True)
    print(f"[MiniLM] model directory: {args.model}", flush=True)
    model = SentenceTransformer(args.model, local_files_only=True)
    dimensions = model.get_sentence_embedding_dimension()
    print(f"[MiniLM] model ready, dimensions={dimensions}", flush=True)
    server = ThreadingHTTPServer((args.host, args.port), EmbeddingHandler)
    server.model = model
    server.api_key = args.api_key
    print(f"[MiniLM] listening on http://{args.host}:{args.port}/v1", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
