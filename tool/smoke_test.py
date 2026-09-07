import json, socket, threading, subprocess, time, sys, os

PORT = 19010
HIT = {'n': 0}
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
            if req['op'] != 'get_state': continue
            HIT['n'] += 1
            with open('test/fixtures/exchanges/get_state_ok.ndjson') as f:
                body = f.read()
            conn.sendall(body.replace('"id":42', '"id":%d' % req['id']).encode())
    conn.close()

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', PORT)); srv.listen(16)
def acceptor():
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
threading.Thread(target=acceptor, daemon=True).start()

env = dict(os.environ, DART_CTRL_HOST='127.0.0.1', DART_CTRL_PORT=str(PORT))
p = subprocess.Popen(['build/linux/x64/debug/bundle/dart_control_panel'], env=env)
time.sleep(6)
alive = p.poll() is None
print('app alive after 6s:', alive)
print('get_state requests served (should be ~11-12 at 500ms):', HIT['n'])
p.terminate()
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
print('smoke exit code:', p.returncode)
ok = alive and HIT['n'] >= 5
print('SMOKE OK' if ok else 'SMOKE FAILED')
sys.exit(0 if ok else 1)
