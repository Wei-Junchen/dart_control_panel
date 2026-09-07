import json, socket, threading, subprocess, sys

FIXTURES = {
 'get_state': 'test/fixtures/exchanges/get_state_ok.ndjson',
 'get_profiles': 'test/fixtures/exchanges/get_profiles_ok.ndjson',
 'get_schema': 'test/fixtures/exchanges/get_schema_ok.ndjson',
 'heartbeat': 'test/fixtures/exchanges/heartbeat_ok.ndjson',
 'get_logs': 'test/fixtures/exchanges/get_logs_ok.ndjson',
}
PORT = 19003
seen = []
def handle(conn):
    buf = b''
    while True:
        data = conn.recv(65536)
        if not data: break
        buf += data
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            if not line.strip(): continue
            req = json.loads(line.decode('utf-8'))
            seen.append(req['op'])
            if req['op'] not in FIXTURES:
                conn.sendall((json.dumps({'v':1,'type':'error','message':'unknown op'})+'\n').encode()); continue
            with open(FIXTURES[req['op']]) as f: body = f.read()
            conn.sendall(body.replace('"id":42', '"id":%d' % req['id']).encode())
    conn.close()

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', PORT)); srv.listen(8)
def acceptor():
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
threading.Thread(target=acceptor, daemon=True).start()

def run(args):
    r = subprocess.run(['dart', 'run', 'bin/dart_cli.dart', '--host', '127.0.0.1', '--port', str(PORT)] + args,
                       capture_output=True, text=True, timeout=30)
    print('===== %s ===== exit=%d' % (' '.join(args), r.returncode))
    if r.stdout.strip():
        print(r.stdout.strip()[:300])
    if r.stderr.strip():
        print('stderr:', r.stderr.strip()[:300])
    return r.returncode == 0

ok = True
ok &= run(['get_state'])
ok &= run(['get_schema'])
ok &= run(['get_profiles'])
ok &= run(['heartbeat'])
ok &= run(['get_logs', '{"lines":50}'])
print('requests seen:', seen)
print('ALL OK' if ok else 'SOME FAILED')
sys.exit(0 if ok else 1)
