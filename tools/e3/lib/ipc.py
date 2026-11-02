"""ephemeral daemon IPC：ipc.py <ipc.token> <method> [params-json]（macOS：/tmp/<socket 名>）。"""
import json
import socket
import sys

tok_path, method = sys.argv[1], sys.argv[2]
params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
sock_name, token = [l.strip() for l in open(tok_path).read().splitlines()[:2]]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/" + sock_name)
f = s.makefile("rw")
f.write(token + "\n")
f.write(json.dumps({"id": "r", "method": method, "params": params}) + "\n")
f.flush()
resp = json.loads(f.readline())
print(json.dumps(resp, ensure_ascii=False))
sys.exit(0 if resp.get("ok") else 1)
