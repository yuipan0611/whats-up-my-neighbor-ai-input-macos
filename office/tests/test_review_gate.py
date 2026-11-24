"""A requested tool is denied and its sensitive arguments never enter the audit."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

class ReviewGateTests(unittest.TestCase):
    def test_gate_blocks_tool_and_keeps_only_tool_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            audit=Path(tmp)/'audit.jsonl'
            payload={'toolCall':{'name':'write_to_file','args':{'secret':'fictional-private-value'}}}
            result=subprocess.run([sys.executable,'-I',str(Path(__file__).parents[1]/'hands'/'review_gate.py'),
                                   '--audit',str(audit)],input=json.dumps(payload),capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(result.stdout)['decision'],'deny')
            self.assertEqual(json.loads(audit.read_text()),{'denied':True,'tool':'write_to_file'})
            self.assertNotIn('fictional-private-value',audit.read_text()+result.stdout)

if __name__=='__main__': unittest.main()
