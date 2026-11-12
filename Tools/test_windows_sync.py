"""Exercise the actual native TLS transport against an isolated synthetic receiver.

Run from a Swift developer environment; no real transcripts or pairing files are used.
The server binds only the explicitly supplied local LAN address and uses a throwaway key.
"""
import argparse
import datetime
import hashlib
import http.server
import json
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import uuid


def wait_for(predicate, description, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(description)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, PermissionError, json.JSONDecodeError):
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--collector', required=True)
    parser.add_argument('--lan-address', required=True)
    parser.add_argument('--openssl', default=r'C:\Program Files\Git\usr\bin\openssl.exe')
    options = parser.parse_args()
    collector = str(pathlib.Path(options.collector).resolve())
    root = pathlib.Path(__file__).resolve().parents[1] / '.build'
    root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sync-integration-', dir=root) as scratch:
        folder = pathlib.Path(scratch)
        key, cert = folder / 'key.pem', folder / 'cert.pem'
        subprocess.run([options.openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=WorkTimer test', '-keyout', str(key),
                        '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text()).encode('latin1')
                                     if isinstance(ssl.PEM_cert_to_DER_cert(cert.read_text()), str)
                                     else ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
        receiver_id, session_id = str(uuid.uuid4()), str(uuid.uuid4())
        token = uuid.uuid4().hex + uuid.uuid4().hex
        state = {'epoch': str(uuid.uuid4()), 'sessions': {}, 'bodies': 0, 'drop_reply': True}

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.connection.settimeout(10)
                try:
                    body = self.rfile.read(int(self.headers['Content-Length']))
                    if not body:
                        return
                    state['bodies'] += 1
                    request = json.loads(body)
                    assert request['token'] == token and request['receiverID'] == receiver_id
                    revisions = {}
                    for snapshot in request['snapshots']:
                        previous = state['sessions'].get(snapshot['key'])
                        if previous is None or previous['revision'] < snapshot['revision']:
                            state['sessions'][snapshot['key']] = snapshot
                        revisions[snapshot['key']] = snapshot['revision']
                    if state['drop_reply']:
                        state['drop_reply'] = False
                        self.connection.shutdown(socket.SHUT_RDWR)
                        return
                    reply = json.dumps({'version': 1, 'receiverID': receiver_id,
                                        'epoch': state['epoch'], 'revisions': revisions}).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(reply)))
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    self.wfile.write(reply)
                except (OSError, ValueError):
                    pass

        server = http.server.ThreadingHTTPServer((options.lan_address, 0), Handler)
        server.daemon_threads = True
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        fixture = folder / 'home' / '.codex' / 'sessions'
        fixture.mkdir(parents=True)
        transcript = fixture / 'synthetic.jsonl'
        stamp = lambda offset: (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=offset)).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        def append_event(event, offset):
            with transcript.open('a') as stream:
                stream.write(json.dumps({'timestamp': stamp(offset), 'type': 'event_msg',
                                         'payload': {'type': event}}, separators=(',', ':')) + '\n')
        transcript.write_text(json.dumps({'timestamp': stamp(-65), 'type': 'session_meta', 'payload': {
            'id': session_id, 'cwd': str(folder), 'originator': 'codex_cli_rs', 'source': 'cli'}}, separators=(',', ':')) + '\n')
        append_event('task_started', -60)
        append_event('token_count', -5)
        pairing = {'version': 1, 'receiverID': receiver_id, 'host': options.lan_address,
                   'port': server.server_port, 'certificateSHA256': fingerprint, 'token': token}
        processes = []
        def launch(directory, pin):
            directory.mkdir(exist_ok=True)
            (directory / 'pairing.json').write_text(json.dumps({**pairing, 'certificateSHA256': pin}))
            process = subprocess.Popen([collector, '--home', str(folder / 'home'), '--data-dir', str(directory)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
            processes.append(process)
            return process
        try:
            bad = launch(folder / 'bad-pin', '0' * 64)
            wait_for(lambda: read_json(folder / 'bad-pin' / 'collector-history.json').get('sessions'), 'Bad-pin collector did not save locally')
            time.sleep(4)
            assert state['bodies'] == 0, 'Data was sent before authenticating the certificate'
            assert bad.poll() is None
            bad.terminate(); bad.wait(timeout=5)
            print('PASS: incorrect certificate pin sends no credential or timing body; offline history is saved')
            data_dir = folder / 'good'
            good = launch(data_dir, fingerprint)
            history_file = data_dir / 'collector-history.json'
            wait_for(lambda: len(state['sessions']) == 1 and state['bodies'] >= 2,
                     'Pinned TLS upload or retry after lost acknowledgement failed')
            append_event('task_complete', 0)
            wait_for(lambda: read_json(history_file).get('pending') == [], 'Completed session was not acknowledged')
            assert len(state['sessions']) == 1
            print('PASS: pinned HTTPS succeeds; lost acknowledgement is retried without duplicate sessions')
            state['sessions'] = {}; state['epoch'] = str(uuid.uuid4())
            wait_for(lambda: len(state['sessions']) == 1, 'Receiver restore did not trigger full replay')
            print('PASS: receiver epoch change replays previously acknowledged history')
            good.terminate(); good.wait(timeout=5)
            transcript.unlink()
            restarted = launch(data_dir, fingerprint)
            wait_for(lambda: read_json(history_file).get('pending') == [], 'Restarted collector did not reconcile')
            time.sleep(2)
            assert len(read_json(history_file)['sessions']) == 1 and restarted.poll() is None
            print('PASS: collector restart and source deletion retain durable normalized history')
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
