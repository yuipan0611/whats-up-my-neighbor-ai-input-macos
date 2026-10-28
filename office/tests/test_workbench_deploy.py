"""Exercise rollback against real files/SQLite; replace only Linux service and ownership operations."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('workbench_deploy',Path(__file__).parents[1]/'workbench'/'deploy.py')
deploy=importlib.util.module_from_spec(spec); spec.loader.exec_module(deploy)

class RollbackTests(unittest.TestCase):
    def test_rollback_preserves_new_data_and_prevents_old_worker_claiming_collaboration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); (root/'data').mkdir(); helpers=root/'helpers'; helpers.mkdir()
            unit=root/'office.service'; unit.write_text('new service')
            backup=root/'backup'; (backup/'helpers').mkdir(parents=True)
            (backup/'helpers'/'worker.py').write_text('old worker')
            (helpers/'worker.py').write_text('new worker')
            (backup/'neighbor-office.service').write_text('old service')
            old=root/'old'; old.mkdir(); (root/'current').symlink_to(root/'new')
            (backup/'deployment.json').write_text(json.dumps({'old_target':str(old),'old_version':'old',
                                                            'flags':{'paused':'0','hands_locked':'0'}}))
            with sqlite3.connect(root/'data/office.sqlite3') as c:
                c.executescript('CREATE TABLE settings(key TEXT,value TEXT); CREATE TABLE tasks(workflow TEXT,status TEXT,stage TEXT); '
                                "INSERT INTO settings VALUES('paused','1'),('hands_locked','1'); "
                                "INSERT INTO tasks VALUES('collaborate','queued',''),('','completed','saved after backup');")
            with patch.multiple(deploy,ROOT=root,UNIT=unit,HELPERS_ROOT=helpers), patch.object(deploy,'service'), \
                 patch.object(deploy,'run'), patch.object(deploy,'wait_health',return_value={'version':'old'}), patch('builtins.print'):
                deploy.restore(backup)
            self.assertEqual((root/'current').resolve(),old.resolve())
            self.assertEqual(unit.read_text(),'old service')
            self.assertEqual((helpers/'worker.py').read_text(),'old worker')
            with sqlite3.connect(root/'data/office.sqlite3') as c:
                self.assertEqual(dict(c.execute('SELECT key,value FROM settings')),{'paused':'0','hands_locked':'0'})
                rows=c.execute('SELECT status,stage FROM tasks').fetchall()
            self.assertEqual(rows[0][0],'interrupted')
            self.assertEqual(rows[1],('completed','saved after backup'))

if __name__=='__main__': unittest.main()
