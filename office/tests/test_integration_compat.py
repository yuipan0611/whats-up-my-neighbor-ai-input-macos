"""Integration boundary: retain both observation contracts without exporting task/provider contents."""
from contextlib import contextmanager
import json
from pathlib import Path
import tempfile
import unittest
import uuid
from test_office import app, FakeModel


class MetadataPort:
    def __init__(self): self.events=[]
    @contextmanager
    def task(self, task_id, executor, previous_task_id=''):
        self.events.append(('task',task_id,executor,previous_task_id))
        yield self
    def outcome(self, status): self.events.append(('outcome',status))
    @contextmanager
    def agent(self, task_id, executor):
        self.events.append(('agent',task_id,executor)); yield self
    def event(self,event): self.events.append(event)
    def shutdown(self, timeout_seconds=2): pass


class CompatibilityTests(unittest.TestCase):
    def test_metadata_port_and_opaque_handle_observers_remain_interchangeable(self):
        # TracePort has reporter.outcome(status); TaskObserver has observer.outcome(handle,status).
        class Port:
            def __init__(self): self.receiver=MetadataPort()
            def task(self,*args): return self.receiver.task(*args)
            def agent(self,*args): return self.receiver.agent(*args)
            def shutdown(self,*args): pass
        port=Port()
        with tempfile.TemporaryDirectory() as tmp:
            store=app.Store(Path(tmp)/'data')
            office=app.Office(store,FakeModel(),telemetry=port)
            task=office.command({'id':str(uuid.uuid4()),'prompt':'寫一句問候 PRIVATE_TASK_SENTINEL'})['task']
            office.execute(store.claim())
            self.assertEqual(store.get(task['id'])['status'],'completed')
            agent=app.CodexAgent(Path(tmp)/'runtime',port)
            with agent.telemetry.agent(task) as observer:
                observer.event({'type':'item.completed','item':{'id':'search-1','type':'web_search','query':'PRIVATE_QUERY_SENTINEL'}})
                observer.event({'type':'unrecognized','secret':'PRIVATE_UNKNOWN_SENTINEL'})
            values=json.dumps(port.receiver.events)
            self.assertNotIn('PRIVATE_',values)
            self.assertIn('web_search',values)
            self.assertIn('completed',values)


if __name__=='__main__': unittest.main()
