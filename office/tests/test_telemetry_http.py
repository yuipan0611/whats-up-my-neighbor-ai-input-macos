"""Exercise the real OTLP exporter against a loopback-only collector fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from test_office import app, FakeModel
from test_thinking import FAKE_CODEX

try:
    from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest
    import openinference.semconv.trace  # noqa: F401
    import opentelemetry.exporter.otlp.proto.http.trace_exporter  # noqa: F401
    HAS_SDK = True
except ImportError:
    HAS_SDK = False


@unittest.skipUnless(HAS_SDK, 'optional tracing dependencies are not installed')
class OTLPHTTPTests(unittest.TestCase):
    def test_actual_office_run_exports_standard_protobuf_with_parentage(self):
        received = threading.Event()
        requests = []

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
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        endpoint = f'http://127.0.0.1:{server.server_port}/v1/traces'
        # Explicit configuration prevents host SDK sampling or credentials from
        # changing this local, synthetic integration test.
        with patch.dict(os.environ, {'NEKO_TRACE_ENABLED': '1',
                                     'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': endpoint,
                                     'OTEL_TRACES_SAMPLER': 'always_on'}, clear=True):
            telemetry = app.load_telemetry()
            self.addCleanup(telemetry.shutdown)
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                store = app.Store(root / 'data')
                agent = app.CodexAgent(root / 'runtime', telemetry)
                agent.binary.parent.mkdir()
                agent.binary.write_text('#!/usr/bin/env python3\n' + FAKE_CODEX)
                agent.binary.chmod(0o700)
                (agent.binary.parent / 'codex-code-mode-host').write_text('fixture host presence')
                office = app.Office(store, FakeModel(), agent, telemetry)
                task_id = str(uuid.uuid4())
                office.command({'id': task_id, 'prompt': 'PRIVATE_OTLP_PROMPT_SENTINEL'})
                office.execute(store.claim())
                self.assertEqual(store.get(task_id)['status'], 'completed')
                # Shutdown drains the real BatchSpanProcessor without replacing
                # its exporter, serialization or HTTP transport with a mock.
                telemetry.shutdown()
                self.assertTrue(received.wait(2), 'local collector received no export')
        spans = {}
        for path, content_type, body in requests:
            self.assertEqual(path, '/v1/traces')
            self.assertEqual(content_type, 'application/x-protobuf')
            self.assertNotIn(b'PRIVATE_OTLP_PROMPT_SENTINEL', body)
            self.assertNotIn(b'Hostinger', body)
            message = ExportTraceServiceRequest.FromString(body)
            for resource in message.resource_spans:
                attributes = {entry.key: entry.value.string_value for entry in resource.resource.attributes}
                self.assertEqual(attributes['service.name'], 'nekonode-office')
                for scope in resource.scope_spans:
                    for span in scope.spans:
                        spans[span.name] = span
        self.assertEqual(set(spans), {'office.task', 'codex.run', 'codex.web_search'})
        task, agent, tool = (spans[name] for name in ('office.task', 'codex.run', 'codex.web_search'))
        self.assertEqual(agent.parent_span_id, task.span_id)
        self.assertEqual(tool.parent_span_id, agent.span_id)
        self.assertEqual({task.trace_id, agent.trace_id, tool.trace_id}, {task.trace_id})
        self.assertTrue(task.trace_id and any(task.trace_id))

    def test_invalid_endpoint_is_rejected_before_starting_exporter(self):
        for endpoint in ('', 'file:///tmp/trace', 'https://user:secret@example.test/v1/traces',
                         'https://example.test/v1/traces?token=secret', 'https://example.test/#secret'):
            with self.subTest(endpoint=endpoint), patch.dict(
                    os.environ, {'NEKO_TRACE_ENABLED': '1',
                                 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': endpoint}, clear=True):
                with self.assertRaises(SystemExit) as error:
                    app.load_telemetry()
                self.assertNotIn('secret', str(error.exception))


if __name__ == '__main__':
    unittest.main()
