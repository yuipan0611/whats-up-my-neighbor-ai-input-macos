#!/usr/bin/env python3
"""Run the same synthetic office task against two real, local OTLP backends.

Only this lab script knows the viewers' query APIs. Office task execution and
the OTLP exporter are unchanged between runs. No model or account is used.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from unittest.mock import patch
import urllib.error
import urllib.parse
import urllib.request
import uuid


PRIVATE = 'NEKONODE_LAB_PRIVATE_CONTENT_SENTINEL'
PROJECT = 'nekonode-replacement-lab'
RESULT = 'Synthetic collector replacement verification completed.'
SPAN_NAMES = frozenset(('office.task', 'codex.run', 'codex.web_search'))
HTTP_TIMEOUT = 3
POLL_SECONDS = 30
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


class VerificationError(Exception):
    pass


def loopback_url(value):
    """Require literal loopback addresses, with no DNS or credential surprises."""
    try:
        parsed = urllib.parse.urlsplit(value)
        address = ipaddress.ip_address(parsed.hostname or '')
        port = parsed.port
    except ValueError:
        raise argparse.ArgumentTypeError('Use an HTTP(S) URL with a literal loopback address.') from None
    if (parsed.scheme not in ('http', 'https') or not address.is_loopback or
            parsed.username or parsed.password or parsed.query or parsed.fragment or
            parsed.path not in ('', '/') or port == 0):
        raise argparse.ArgumentTypeError('Use a loopback HTTP(S) base URL without credentials, path, query or fragment.')
    return value.rstrip('/')


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        # A local test URL must not redirect the verifier to an outside service.
        return None


HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())


def request(url, timeout=HTTP_TIMEOUT):
    with HTTP.open(url, timeout=min(HTTP_TIMEOUT, timeout)) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            raise VerificationError('Query response exceeded the lab size limit.')
        text = body.decode('utf-8')
        if PRIVATE in text:
            raise VerificationError('Private fixture content was found in backend query output.')
        return response.status, response.headers.get('Content-Type', ''), text


def json_request(url, timeout=HTTP_TIMEOUT):
    return json.loads(request(url, timeout)[2])


def identifier(value, size, *, parent=False):
    if value is None or value == '':
        if parent:
            return None
        raise VerificationError('A backend returned an empty span or trace identifier.')
    if not isinstance(value, str):
        raise VerificationError('A backend returned an invalid identifier type.')
    if re.fullmatch(r'[0-9a-fA-F]{' + str(size * 2) + '}', value):
        result = value.lower()
    else:
        # The stable Jaeger gRPC gateway may use protobuf-JSON bytes (base64).
        try:
            decoded = base64.b64decode(value, validate=True)
        except ValueError:
            raise VerificationError('A backend returned an invalid encoded identifier.') from None
        if len(decoded) != size:
            raise VerificationError('A backend returned an identifier of the wrong length.')
        result = decoded.hex()
    if parent and int(result, 16) == 0:
        return None
    return result


def any_value(value):
    for key in ('stringValue', 'string_value', 'boolValue', 'bool_value', 'doubleValue', 'double_value'):
        if key in value:
            return value[key]
    for key in ('intValue', 'int_value'):
        if key in value:
            return int(value[key])
    for key in ('arrayValue', 'array_value'):
        if key in value:
            return [any_value(item) for item in value[key].get('values', [])]
    for key in ('kvlistValue', 'kvlist_value'):
        if key in value:
            return key_values(value[key].get('values', []))
    for key in ('bytesValue', 'bytes_value'):
        if key in value:
            return base64.b64decode(value[key]).decode('utf-8', errors='replace')
    return None


def key_values(values):
    return {item['key']: any_value(item.get('value', {})) for item in values}


def timestamp_ns(value):
    if type(value) is int or isinstance(value, str) and value.isdigit():
        result = int(value)
    elif isinstance(value, str):
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise VerificationError('Backend timestamps must include a timezone.')
        delta = parsed - datetime(1970, 1, 1, tzinfo=timezone.utc)
        result = ((delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds) * 1000
    else:
        raise VerificationError('A backend omitted a trace timestamp.')
    if result <= 0:
        raise VerificationError('A backend returned an invalid trace timestamp.')
    return result


def phoenix_spans(base, trace_id, timeout=HTTP_TIMEOUT):
    query = urllib.parse.urlencode({'trace_id': trace_id, 'limit': 100})
    data = json_request(f'{base}/v1/projects/{PROJECT}/spans?{query}', timeout)
    records = []
    for span in data.get('data', []):
        attributes = dict(span.get('attributes', {}))
        attributes['openinference.span.kind'] = span.get('span_kind', 'UNKNOWN')
        records.append({
            'name': span['name'],
            'trace_id': identifier(span['context']['trace_id'], 16),
            'span_id': identifier(span['context']['span_id'], 8),
            'parent_span_id': identifier(span.get('parent_id'), 8, parent=True),
            'attributes': attributes,
            'status': span.get('status_code'),
            'start': span.get('start_time'),
            'end': span.get('end_time'),
        })
    return records


def jaeger_spans(base, trace_id, timeout=HTTP_TIMEOUT):
    raw = request(f'{base}/api/v3/traces/{trace_id}', timeout)[2]
    try:
        chunks = [json.loads(raw)]
    except json.JSONDecodeError:
        chunks = [json.loads(line) for line in raw.splitlines() if line.strip()]
    records = []
    for chunk in chunks:
        if 'error' in chunk:
            raise VerificationError('Jaeger reported a query-stream error.')
        data = chunk.get('result', chunk)
        for resource in data.get('resourceSpans', data.get('resource_spans', [])):
            for scope in resource.get('scopeSpans', resource.get('scope_spans', [])):
                for span in scope.get('spans', []):
                    code = span.get('status', {}).get('code', 0)
                    status = {0: 'UNSET', 1: 'OK', 2: 'ERROR',
                              'STATUS_CODE_UNSET': 'UNSET', 'STATUS_CODE_OK': 'OK',
                              'STATUS_CODE_ERROR': 'ERROR'}.get(code, str(code))
                    records.append({
                        'name': span['name'],
                        'trace_id': identifier(span.get('traceId', span.get('trace_id')), 16),
                        'span_id': identifier(span.get('spanId', span.get('span_id')), 8),
                        'parent_span_id': identifier(span.get('parentSpanId', span.get('parent_span_id')), 8, parent=True),
                        'attributes': key_values(span.get('attributes', [])),
                        'status': status,
                        'start': span.get('startTimeUnixNano', span.get('start_time_unix_nano')),
                        'end': span.get('endTimeUnixNano', span.get('end_time_unix_nano')),
                    })
    return records


def poll_spans(reader, base, trace_id):
    deadline = time.monotonic() + POLL_SECONDS
    while time.monotonic() < deadline:
        try:
            records = reader(base, trace_id, timeout=max(0.001, deadline - time.monotonic()))
        except urllib.error.HTTPError as error:
            if error.code not in (404, 429, 502, 503):
                raise VerificationError(f'Backend query returned HTTP {error.code}.') from None
            records = []
        if len(records) >= len(SPAN_NAMES):
            return records
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    raise VerificationError('The backend did not return all three spans within 30 seconds.')


class UnusedModel:
    model = 'synthetic-unused-model'

    def generate(self, *args, **kwargs):
        raise VerificationError('The synthetic Codex path unexpectedly invoked another model.')


def load_office():
    path = Path(__file__).resolve().parents[1] / 'office.py'
    spec = importlib.util.spec_from_file_location('lab_office', path)
    office = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(office)
    return office


def run_task(office_module, endpoint, task_id):
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    environment = {
        'PATH': str(Path(sys.executable).parent) + os.pathsep + os.defpath,
        'LANG': 'C.UTF-8',
        'NEKO_TRACE_ENABLED': '1',
        'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT': endpoint,
        'OTEL_TRACES_SAMPLER': 'always_on',
        'OTEL_RESOURCE_ATTRIBUTES': 'openinference.project.name=' + PROJECT,
    }
    # Exclude host sampler settings, SDK_DISABLED, exporter headers, proxies,
    # API keys and other resource attributes from this synthetic lab process.
    with patch.dict(os.environ, environment, clear=True), tempfile.TemporaryDirectory(prefix='nekonode-backend-lab-') as directory:
        telemetry = office_module.load_telemetry()
        capture = InMemorySpanExporter()
        telemetry.provider.add_span_processor(SimpleSpanProcessor(capture))
        try:
            root = Path(directory)
            store = office_module.Store(root / 'data')
            agent = office_module.CodexAgent(root / 'runtime', telemetry)
            agent.binary.parent.mkdir()
            fixture = (
                '#!/usr/bin/env python3\nimport json,sys,pathlib\n'
                "if sys.argv[1:]==['login','status']: sys.exit(0)\n"
                'sys.stdin.read()\n'
                f'private={PRIVATE!r}\n'
                "def emit(phase, **item): print(json.dumps({'type':phase,'item':item}), flush=True)\n"
                "emit('item.completed', id='reasoning-1', type='reasoning', text=private)\n"
                "emit('item.started', id='search-1', type='web_search', query=private)\n"
                "emit('item.completed', id='search-1', type='web_search', query=private)\n"
                "print(json.dumps({'type':'turn.completed','usage':{'input_tokens':11,'output_tokens':5}}), flush=True)\n"
                f"result={{'kind':'completed','content':{RESULT!r},'next_step':''}}\n"
                "pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text(json.dumps(result))\n"
            )
            agent.binary.write_text(fixture, encoding='utf-8')
            agent.binary.chmod(0o700)
            (agent.binary.parent / 'codex-code-mode-host').write_text('synthetic fixture host presence')
            store.upload('synthetic.txt', PRIVATE)
            office = office_module.Office(store, UnusedModel(), agent, telemetry)
            office.command({'id': task_id, 'prompt': PRIVATE, 'source': 'synthetic.txt'})
            office.execute(store.claim())
            task = store.get(task_id)
            if task['status'] != 'completed' or task['result'] != RESULT:
                raise VerificationError('The synthetic office task did not save the expected completed result.')
            finished = tuple(capture.get_finished_spans())
            expected = [{
                'name': span.name,
                'trace_id': f'{span.context.trace_id:032x}',
                'span_id': f'{span.context.span_id:016x}',
                'parent_span_id': f'{span.parent.span_id:016x}' if span.parent else None,
                'start_ns': span.start_time,
                'end_ns': span.end_time,
            } for span in finished]
            if len(expected) != 3 or {span['name'] for span in expected} != SPAN_NAMES:
                raise VerificationError('The application did not produce the three expected SDK spans.')
            if any(PRIVATE in span.to_json() for span in finished):
                raise VerificationError('The application included private fixture content in a trace.')
            saved = {'status': task['status'],
                     'result_sha256': hashlib.sha256(task['result'].encode()).hexdigest(),
                     'event_statuses': [event['status'] for event in task['events']]}
        finally:
            telemetry.shutdown()
    return expected, saved


def validate_records(records, expected, task_id):
    by_name = {record['name']: record for record in records}
    if len(records) != 3 or set(by_name) != SPAN_NAMES:
        raise VerificationError('Backend span names or count differ from actual application execution.')
    for original in expected:
        actual = by_name[original['name']]
        if any(actual[key] != original[key] for key in ('trace_id', 'span_id', 'parent_span_id')):
            raise VerificationError('Backend trace IDs or parent relationships differ from emitted spans.')
        if actual['status'] != 'OK' or actual['attributes'].get('nekonode.status') != 'completed':
            raise VerificationError('The backend did not preserve completion status.')
        start_ns, end_ns = timestamp_ns(actual['start']), timestamp_ns(actual['end'])
        # Phoenix exposes microsecond datetime precision; Jaeger preserves ns.
        # Allow only rounding at that precision, not arbitrary clock changes.
        if (end_ns < start_ns or abs(start_ns - original['start_ns']) > 2000 or
                abs(end_ns - original['end_ns']) > 2000):
            raise VerificationError('The backend did not preserve the observed execution times.')
    task, agent, tool = (by_name[name] for name in ('office.task', 'codex.run', 'codex.web_search'))
    if task['parent_span_id'] is not None or agent['parent_span_id'] != task['span_id'] or tool['parent_span_id'] != agent['span_id']:
        raise VerificationError('The backend did not preserve task / agent / tool parentage.')
    if task['attributes'].get('nekonode.task.id') != task_id or agent['attributes'].get('nekonode.task.id') != task_id:
        raise VerificationError('The backend did not preserve the office task identifier.')
    if len({record['trace_id'] for record in records}) != 1:
        raise VerificationError('The backend split one execution into multiple traces.')
    if PRIVATE in json.dumps(records, ensure_ascii=False):
        raise VerificationError('Private fixture content appeared in decoded backend attributes.')
    return [by_name[name] for name in ('office.task', 'codex.run', 'codex.web_search')]


def check_ui(base):
    status, content_type, text = request(base + '/')
    if status != 200 or 'text/html' not in content_type or '<html' not in text.lower():
        raise VerificationError('The viewer home page did not return HTML successfully.')
    return {'http_status': status, 'content_type': content_type, 'html_received': True,
            'visually_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phoenix-url', type=loopback_url, default='http://127.0.0.1:6006')
    parser.add_argument('--jaeger-query-url', type=loopback_url, default='http://127.0.0.1:16686')
    parser.add_argument('--jaeger-otlp-url', type=loopback_url, default='http://127.0.0.1:4318')
    parser.add_argument('--check-ui', action='store_true', help='Also check home-page HTTP responses; this is not visual verification.')
    parser.add_argument('--output', type=Path, help='Save observed, metadata-only JSON evidence.')
    args = parser.parse_args()
    os.umask(0o077)
    report = {'schema_version': 1, 'passed': False,
              'checked_at': datetime.now(timezone.utc).isoformat(),
              'project': PROJECT, 'synthetic_only': True,
              'packages': {name: importlib.metadata.version(name) for name in
                           ('opentelemetry-sdk', 'openinference-semantic-conventions')},
              'backends': []}
    exit_code = 1
    try:
        office = load_office()
        task_id = str(uuid.uuid4())
        for name, query_base, write_base, reader in (
                ('phoenix', args.phoenix_url, args.phoenix_url, phoenix_spans),
                ('jaeger', args.jaeger_query_url, args.jaeger_otlp_url, jaeger_spans)):
            expected, task = run_task(office, write_base + '/v1/traces', task_id)
            trace_id = expected[0]['trace_id']
            records = poll_spans(reader, query_base, trace_id)
            evidence = {'backend': name, 'task_id': task_id, 'trace_id': trace_id,
                        'collector_endpoint': write_base + '/v1/traces',
                        'query_base_url': query_base, 'task': task,
                        'queried_spans': validate_records(records, expected, task_id),
                        'passed': True}
            if name == 'phoenix':
                evidence['server_version'] = request(query_base + '/arize_phoenix_version')[2].strip()
            if args.check_ui:
                evidence['ui_http_check'] = check_ui(query_base)
            report['backends'].append(evidence)
            print(f'{name}: queried and verified 3 spans from the real backend.', flush=True)
        if report['backends'][0]['task'] != report['backends'][1]['task']:
            raise VerificationError('Replacing the collector changed the task result or durable event sequence.')
        report['passed'] = True
        exit_code = 0
    except (VerificationError, urllib.error.URLError, TimeoutError, ValueError, KeyError) as error:
        report['error'] = {'type': type(error).__name__, 'message': str(error)}
        print('Backend replacement verification failed: ' + str(error), file=sys.stderr)
    finally:
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print('Backend replacement verification: ' + ('PASS' if report['passed'] else 'FAIL'), flush=True)
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
