#!/usr/bin/env python3
"""A minimal MCP server (stdio) for Watercoded's live tests.

Its one tool, `ask_profile`, asks the client for a form (MCP elicitation) and returns what came back,
so tests can check that a form request reaches the user and the answers reach the tool.
"""
import json
import sys

SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "title": "Your name", "description": "What should we call you?"},
        "role": {"type": "string", "title": "Role", "oneOf": [
            {"const": "dev", "title": "Developer"}, {"const": "design", "title": "Designer"}]},
        "subscribe": {"type": "boolean", "title": "Subscribe", "default": False},
    },
    "required": ["name", "role"],
}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


pending_call = None
for raw in sys.stdin:
    message = json.loads(raw)
    method = message.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {
            "protocolVersion": message["params"].get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "elicitation-test", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"tools": [{
            "name": "ask_profile", "description": "Asks the user for their profile and returns it.",
            "inputSchema": {"type": "object", "properties": {}}}]}})
    elif method == "tools/call":
        pending_call = message["id"]
        send({"jsonrpc": "2.0", "id": "elicit-1", "method": "elicitation/create", "params": {
            "message": "Please fill in your profile.", "requestedSchema": SCHEMA}})
    elif message.get("id") == "elicit-1" and pending_call is not None:
        result = message.get("result", {})
        text = "action=%s content=%s" % (result.get("action"), json.dumps(result.get("content"), sort_keys=True))
        send({"jsonrpc": "2.0", "id": pending_call, "result": {"content": [{"type": "text", "text": text}]}})
        pending_call = None
    elif "id" in message and method:
        send({"jsonrpc": "2.0", "id": message["id"], "result": {}})
