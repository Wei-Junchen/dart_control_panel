import json, socket, threading, sys, os

FIXTURES = {
 'get_state': 'test/fixtures/exchanges/get_state_ok.ndjson',
 'get_profiles': 'test/fixtures/exchanges/get_profiles_ok.ndjson',
 'get_schema': 'test/fixtures/exchanges/get_schema_ok.ndjson',
 'heartbeat': 'test/fixtures/exchanges/heartbeat_ok.ndjson',
}

def handle(conn):
    buf = b''
    while True:
        data = conn.recv(4096)
        if not data:
            break
        buf += data
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            if not line.strip():
                continue
            req = json.loads(line.decode('utf-8'))
            op = req['op']
            rid = req['id']
            if op not in FIXTURES:
                conn.sendall((json.dumps({'v':1,'type':'error','message':'unknown op'})+'\n').encode())
                continue
            with open(FIXTURES[op]) as f:
                body = f.read()
            body = body.replace('"id":42', '"id":%d' % rid)
            conn.sendall(body.encode())
    conn.close()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19000
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', port))
    srv.listen(16)
    print('mock daemon on %d' % port, flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

main()
