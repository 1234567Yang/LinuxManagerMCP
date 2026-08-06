#!/usr/bin/env python3
"""最小 MCP 客户端:走完握手,调一次 ls,把每一步的原始报文打出来。"""

import json
import urllib.error
import urllib.request

TOKEN = "my_secret_token"
URL = "https://example.com/mcp"
PROTO = "2025-11-25"

session_id = None


def post(payload):
    global session_id

    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
        # 两个 media type 都必须给,少一个服务端直接返回 406
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
        headers["MCP-Protocol-Version"] = PROTO

    body = json.dumps(payload)
    print(f"\n>>>>> 请求\n{body}")

    req = urllib.request.Request(URL, data=body.encode(), headers=headers, method="POST")
    try:
        resp = urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        resp = e  # HTTPError 本身就是响应对象,可以照常读

    raw = resp.read().decode("utf-8", "replace")
    print(f"<<<<< 响应 {resp.status}")
    for k, v in resp.headers.items():
        print(f"  {k}: {v}")
    print(raw or "  (空 body)")

    # initialize 的响应头里带 session id,后续请求必须回传
    if resp.headers.get("mcp-session-id"):
        session_id = resp.headers["mcp-session-id"]


# 1. initialize
post({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": PROTO,
        "capabilities": {},
        "clientInfo": {"name": "probe", "version": "0"},
    },
})

# 2. 握手完成。没有 id 所以这是 notification,服务端回 202 空 body
post({"jsonrpc": "2.0", "method": "notifications/initialized"})

# 3. 看服务端声明的工具和 schema
post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})

# 4. 调用
post({
    "jsonrpc": "2.0", "id": 3, "method": "tools/call",
    "params": {
        "name": "execute_command",
        "arguments": {"command": "ls"},
    },
})