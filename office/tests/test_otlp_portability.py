"""Test the configurable wire boundary with two independent OTLP receivers.

These fixtures are not Phoenix/Jaeger installations. Backend-specific UI, query
APIs, authentication and historical trace migration require separate acceptance.
"""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from test_office import app, FakeModel
from test_observation_portability import ports

try:
    from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest
    import opentelemetry.exporter.otlp.proto.http.trace_exporter
    import openinference.semconv.trace
except ImportError:
    HAS_SDK = False
else:
    HAS_SDK = True


@contextmanager
def receiver():
    requests, received = [], threading.Event()

    class Collector(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            requests.append((self.path, self.headers.get('Content-Type'),
                             self.rfile.read(int(self.headers['Content-Length']))))
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-protobuf')
            self.send_header('Content-Length', '0')
            self.end_headers()
            received.set()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Collector)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/v1/traces', requests, received
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)


@unittest.skipUnless(HAS_SDK, 'optional tracing dependencies are not installed')
class OTLPPortabilityTests(unittest.TestCase):
    def run_on(self, endpoint, directory):
        with patch.dict(os.environ, {'NEKO_TRACE_ENABLED': '1',
                                     'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': endpoint,
                                     'OTEL_TRACES_SAMPLER': 'always_on'}, clear=True):
            telemetry = app.load_telemetry()
            self.assertIsInstance(telemetry, ports.TaskObserver)
            self.assertIsInstance(telemetry, ports.CodexObserver)
            try:
                store = app.Store(directory)
                office = app.Office(store, FakeModel(), telemetry=telemetry)
                task_id = str(uuid.uuid4())
                office.command({'id': task_id, 'prompt': 'PRIVATE_PORTABILITY_PROMPT'})
                office.execute(store.claim())
                saved = store.get(task_id)
                return task_id, saved['status'], saved['result'], [e['status'] for e in saved['events']]
            finally:
                telemetry.shutdown()

    def verify(self, requests, task_id):
        spans = []
        for path, content_type, body in requests:
            self.assertEqual(path, '/v1/traces')
            self.assertEqual(content_type, 'application/x-protobuf')
            self.assertNotIn(b'PRIVATE_PORTABILITY_PROMPT', body)
            message = ExportTraceServiceRequest.FromString(body)
            for resource in message.resource_spans:
                for scope in resource.scope_spans:
                    spans.extend(scope.spans)
        self.assertEqual(len(spans), 1)
        span = spans[0]
        self.assertEqual(span.name, 'office.task')
        self.assertEqual(span.parent_span_id, b'')
        attributes = {entry.key: entry.value.string_value for entry in span.attributes}
        self.assertEqual(attributes['nekonode.task.id'], task_id)
        self.assertEqual(attributes['nekonode.status'], 'completed')
        self.assertEqual(attributes['openinference.span.kind'], 'CHAIN')
        self.assertEqual(len(span.trace_id), 16)
        self.assertTrue(any(span.trace_id))
        return span.trace_id

    def test_new_receiver_works_after_old_receiver_is_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            with receiver() as (endpoint_a, requests_a, received_a):
                first = self.run_on(endpoint_a, Path(directory) / 'a')
                self.assertTrue(received_a.wait(2), 'first receiver got no export')
                trace_a = self.verify(requests_a, first[0])
            # The old service is gone. Only the endpoint configuration changes;
            # no task code, SDK, exporter or serialization is replaced/mocked.
            first_count = len(requests_a)
            with receiver() as (endpoint_b, requests_b, received_b):
                second = self.run_on(endpoint_b, Path(directory) / 'b')
                self.assertTrue(received_b.wait(2), 'replacement receiver got no export')
                trace_b = self.verify(requests_b, second[0])
            self.assertEqual(first[1:], second[1:])
            self.assertEqual(first[1], 'completed')
            self.assertNotEqual(trace_a, trace_b)
            self.assertEqual(len(requests_a), first_count)


if __name__ == '__main__':
    unittest.main()
