#!/usr/bin/env python3
"""Language-neutral JSONL driver tests against scripted peers and real koutend."""

import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent


def encoded(data):
    return base64.b64encode(data).decode()


class Adapter:
    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, bufsize=1)

    def call(self, op):
        self.process.stdin.write(json.dumps(op) + '\n')
        self.process.stdin.flush()
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(15):
                raise AssertionError('Driver JSONL response timed out')
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError('Driver exited before responding')
        return json.loads(line)

    def ok(self, op):
        response = self.call(op)
        if response.get('ok') is not True:
            raise AssertionError(f'Expected success for {op["op"]}: {response}')
        return response['result']

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise AssertionError('Driver did not exit')
        if self.process.returncode != 0:
            raise AssertionError('Driver exited unsuccessfully')


class Peer:
    def __init__(self, sessions, handshake):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.listener.settimeout(5)
        self.endpoint = '127.0.0.1:' + str(self.listener.getsockname()[1])
        self.sessions = sessions
        self.handshake = handshake
        self.error = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            for session in self.sessions:
                conn, _ = self.listener.accept()
                with conn:
                    conn.settimeout(5)
                    for step in self.handshake + session:
                        expected = step['request'].encode()
                        expected_header, _, expected_body = expected.partition(b'\n')
                        actual_header = b''
                        while not actual_header.endswith(b'\n'):
                            chunk = conn.recv(1)
                            if not chunk:
                                raise AssertionError('Driver disconnected before request completed')
                            actual_header += chunk
                            if len(actual_header) > 8193:
                                raise AssertionError('Driver sent an oversized header')
                        actual_fields = actual_header[:-1].split(b' ')
                        expected_fields = expected_header.split(b' ')
                        if expected_fields[0] in (b'GETID', b'QRYID') and len(actual_fields) == len(expected_fields):
                            # Languages may print the same binary64 as 60 or 60.0.
                            for index in (4, 5, 6):
                                if float(actual_fields[index]) == float(expected_fields[index]):
                                    actual_fields[index] = expected_fields[index]
                        if actual_fields != expected_fields:
                            raise AssertionError('Wire request differs from fixture')
                        received = b''
                        if step.get('readBody', True):
                            while len(received) < len(expected_body):
                                chunk = conn.recv(len(expected_body) - len(received))
                                if not chunk:
                                    raise AssertionError('Driver disconnected before body completed')
                                received += chunk
                            if received != expected_body:
                                raise AssertionError('Wire request body differs from fixture')
                        if step.get('disconnect'):
                            break
                        time.sleep(step.get('delay', 0))
                        payload = (base64.b64decode(step['responseBase64'], validate=True)
                                   if 'responseBase64' in step else step.get('response', '').encode())
                        chunk_size = step.get('chunk', max(1, len(payload)))
                        for offset in range(0, len(payload), chunk_size):
                            conn.sendall(payload[offset:offset + chunk_size])
                            if step.get('chunk'):
                                time.sleep(0.001)
                        if step.get('expectClose') and conn.recv(1) != b'':
                            raise AssertionError('Driver reused a poisoned stream')
            # A mutation must never be retried on another freshly opened connection.
            self.listener.settimeout(0.2)
            try:
                extra, _ = self.listener.accept()
            except socket.timeout:
                pass
            else:
                extra.close()
                raise AssertionError('Unexpected reconnect beyond fixture sessions')
        except Exception as error:
            self.error = error
        finally:
            self.listener.close()

    def finish(self):
        self.thread.join(7)
        if self.thread.is_alive():
            raise AssertionError('Scripted peer did not finish')
        if self.error:
            raise self.error


def fixtures(command):
    spec = json.loads((ROOT / 'tests/fixtures/native-wire-v1.json').read_text())
    for case in spec['cases']:
        peer = Peer(case['sessions'], spec['handshake'])
        adapter = Adapter(command)
        try:
            adapter.ok({'op': 'connect', 'peers': [peer.endpoint], **case.get('connect', {})})
            op = dict(case['op'])
            if op.get('id') == '$id':
                op['id'] = spec['id']
            response = adapter.call(op)
            if 'error' in case:
                assert response.get('ok') is False and response.get('error') == case['error'], (case['name'], response)
                assert 'secret-password' not in json.dumps(response)
            else:
                assert response.get('ok') is True and response.get('result') == case['result'], (case['name'], response)
        finally:
            adapter.close()
            peer.finish()
        print('PASS fixture ' + case['name'], flush=True)

    for name, reply, error in [('version-mismatch', 'WIREVER 999\n', 'VersionMismatchException'),
                                ('version-malformed', 'WIREVER\n', 'ProtocolException'),
                                ('version-oversized', 'X' * 8193 + '\n', 'ProtocolException')]:
        peer = Peer([[{'request': 'WIREVER\n', 'response': reply}]], [])
        adapter = Adapter(command)
        try:
            response = adapter.call({'op': 'connect', 'peers': [peer.endpoint]})
            assert response.get('error') == error, response
        finally:
            adapter.close()
            peer.finish()
        print('PASS fixture ' + name, flush=True)

    # Cross-node redirect targets are configured peer indexes, not arbitrary URLs.
    second = Peer([[{'request': 'GETID 18446744073709551615 1 7 1.25 60 0.5\n',
                     'response': 'VAL 1 1 raw\nx'}]], spec['handshake'])
    first = Peer([[{'request': 'GETID 18446744073709551615 1 7 1.25 60 0.5\n',
                    'response': 'FWD 18446744073709551615 1 7 1.25 60 0.5 1\n'}]], spec['handshake'])
    adapter = Adapter(command)
    try:
        adapter.ok({'op': 'connect', 'peers': [first.endpoint, second.endpoint]})
        assert adapter.ok({'op': 'get', 'id': spec['id']}) == {'payload': 'eA==', 'codec': 'raw'}
    finally:
        adapter.close()
        first.finish()
        second.finish()
    print('PASS fixture cross-node-redirect', flush=True)

    # Force send-buffer backpressure rather than only delaying a write response.
    payload = b'x' * (8 * 1024 * 1024)
    peer = Peer([[{'request': f'PUTR 1 {len(payload)} 0 raw\n', 'readBody': False, 'delay': 0.3}]], spec['handshake'])
    adapter = Adapter(command)
    try:
        adapter.ok({'op': 'connect', 'peers': [peer.endpoint], 'writeTimeout': 0.05})
        response = adapter.call({'op': 'put', 'ring': 'r', 'payload': encoded(payload)})
        assert response.get('error') == 'IndeterminateWriteException', response
    finally:
        adapter.close()
        peer.finish()
    print('PASS fixture write-backpressure', flush=True)

    peer = Peer([[{'request': 'HEALTH\n', 'response': 'BROKEN\n', 'expectClose': True}],
                 [{'request': 'HEALTH\n', 'response': 'OK node=0\n'}]], spec['handshake'])
    adapter = Adapter(command)
    try:
        adapter.ok({'op': 'connect', 'peers': [peer.endpoint]})
        assert adapter.call({'op': 'health'}).get('error') == 'ProtocolException'
        assert adapter.ok({'op': 'health'}) == 'node=0'
    finally:
        adapter.close()
        peer.finish()
    print('PASS fixture poisoned-stream-not-reused', flush=True)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def server(binary, root, extra):
    port = free_port()
    endpoint = f'127.0.0.1:{port}'
    log_path = root / 'server.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([str(binary), '--id=0', '--peers=' + endpoint,
                                    '--data=' + str(root / 'data'), '--slow-tick=0.05', *extra],
                                   stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while 'listening' not in log_path.read_text():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError('koutend failed to start: ' + log_path.read_text())
                time.sleep(0.05)
            yield endpoint, process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def certificate(root):
    cert, key = root / 'cert.pem', root / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-nodes', '-newkey', 'rsa:2048', '-days', '1',
                    '-keyout', str(key), '-out', str(cert), '-subj', '/CN=localhost',
                    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
                    '-addext', 'extendedKeyUsage=serverAuth'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    return cert, key


def real(command, binary):
    for mode in ['plain', 'password', 'token', 'secret', 'tls', 'tls-secret']:
        with tempfile.TemporaryDirectory(prefix='kouten-native-conformance-') as tmp:
            root = Path(tmp)
            extra = ['--galaxy=publarish']
            options = {'galaxy': 'publarish'}
            if mode in ['password', 'secret', 'tls', 'tls-secret']:
                extra += ['--user=writer', '--password=test-password']
                options.update(username='writer', password='test-password')
            if mode == 'token':
                extra += ['--auth-token=test-token']
                options['authToken'] = 'test-token'
            if 'secret' in mode:
                extra += ['--secret-key=test-secret']
                options['secretKey'] = 'test-secret'
            if mode.startswith('tls'):
                cert, key = certificate(root)
                extra += ['--tls-cert=' + str(cert), '--tls-key=' + str(key)]
                options.update(tls=True, tlsCaFile=str(cert), tlsServerName='localhost')
            with server(binary, root, extra) as (endpoint, process):
                adapter = Adapter(command)
                try:
                    if mode.startswith('tls'):
                        for changes in [{'tlsCaFile': ''}, {'tlsServerName': 'invalid.example'}]:
                            response = adapter.call({'op': 'connect', 'peers': [endpoint], 'options': {**options, **changes}})
                            assert response.get('error') == 'ConnectionException', response
                    if mode != 'plain':
                        bad = {**options, ('authToken' if mode == 'token' else 'password'): 'wrong'}
                        response = adapter.call({'op': 'connect', 'peers': [endpoint], 'options': bad})
                        assert response.get('error') == 'AuthenticationException', response
                    if 'secret' in mode:
                        response = adapter.call({'op': 'connect', 'peers': [endpoint], 'options': {**options, 'secretKey': 'wrong-key'}})
                        assert response.get('error') == 'AuthenticationException', response
                    response = adapter.call({'op': 'connect', 'peers': [endpoint], 'options': {**options, 'galaxy': 'wrong'}})
                    assert response.get('error') == 'AuthenticationException', response
                    adapter.ok({'op': 'connect', 'peers': [endpoint], 'options': options})
                    assert 'node=0' in adapter.ok({'op': 'health'})
                    debug = adapter.ok({'op': 'debug'})
                    assert all(value not in debug for value in ['test-password', 'test-token', 'test-secret'])
                    article = {'title': 'Native JSON', 'status': 'draft'}
                    article_id = adapter.ok({'op': 'putJson', 'ring': 'publarish/articles', 'value': article})
                    assert adapter.ok({'op': 'getJson', 'id': article_id}) == article
                    for payload, codec in [(b'', 'raw'), (b'\x00\xff\x00\xfe', 'bif'),
                                           ('{"title":"日本語 😀","status":"draft"}'.encode(), 'json'),
                                           (b'x' * 1048576, 'raw')]:
                        raw_id = adapter.ok({'op': 'put', 'ring': 'publarish/articles', 'payload': encoded(payload), 'codec': codec})
                        # Use the serialized ID from PUT, not a retained in-memory object.
                        result = adapter.ok({'op': 'get', 'id': raw_id})
                        assert result == {'payload': encoded(payload), 'codec': codec}
                        if codec == 'json':
                            assert adapter.ok({'op': 'query', 'id': raw_id, 'selection': '{ title }'}) == {'title': '日本語 😀'}
                    if mode.startswith('tls'):
                        adapter.ok({'op': 'connect', 'peers': [endpoint], 'options': {
                            **options, 'tlsCaFile': '', 'tlsInsecureSkipVerify': True}})
                        assert 'node=0' in adapter.ok({'op': 'health'})
                    process.terminate()
                    process.wait(5)
                    response = adapter.call({'op': 'health'})
                    assert response.get('error') == 'ConnectionException', response
                    adapter.ok({'op': 'close'})
                    assert adapter.call({'op': 'health'}).get('error') == 'ConnectionException'
                finally:
                    adapter.close()
            print('PASS real ' + mode, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, help='TLS-enabled koutend binary; enables real server tests')
    parser.add_argument('--fixtures-only', action='store_true')
    parser.add_argument('driver', nargs=argparse.REMAINDER, help='JSONL adapter command, after --')
    args = parser.parse_args()
    command = args.driver[1:] if args.driver[:1] == ['--'] else args.driver
    if not command:
        parser.error('a JSONL adapter command is required')
    fixtures(command)
    if args.server and not args.fixtures_only:
        real(command, args.server.resolve())
    print('PASS native driver conformance', flush=True)


if __name__ == '__main__':
    main()
