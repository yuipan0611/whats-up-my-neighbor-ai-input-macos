"""Runner skeleton against FakeRunner (施工單 2026-10-28 第四節).

Everything here is simulated: no real sandbox provider, no network, no account. The git target is a
real git repository in a temporary folder. Fictional data only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid

from test_office import app, FakeModel, local_request

sys.path.insert(0, str(Path(__file__).parents[1]))
import runner as rn  # noqa: E402

CANARY = 'fictional-canary-secret-7731'
PATCH = b'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n'


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, check=True).stdout


class RunnerBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = app.Store(self.root / 'data')
        self.office = app.Office(self.store, FakeModel())
        self.fake = rn.FakeRunner()
        self.service = rn.RunService(self.store, self.fake)
        self.task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：改 README', 'executor': 'hands'})['task']
        self.claimed = self.store.claim_hands()
        self.lease = self.claimed['lease']
        self.work = self.root / 'work'
        self.work.mkdir()
        (self.work / 'README.md').write_text('old\n')
        (self.work / 'src').mkdir()
        (self.work / 'src' / 'app.py').write_text('print(1)\n')
        (self.work / '.env').write_text(f'TOKEN={CANARY}\n')  # must never reach a sandbox

    def tearDown(self):
        self.temp.cleanup()

    def start(self, paths=('README.md', 'src/app.py'), **kw):
        return self.service.start(self.task['id'], self.lease, self.work, list(paths), 'b8599c6', **kw)

    def repo(self):
        repo = self.root / 'repo'
        repo.mkdir()
        git(repo, 'init', '-q')
        git(repo, 'config', 'user.name', 'neko-test')
        git(repo, 'config', 'user.email', 'neko-test@example.test')
        (repo / 'README.md').write_text('old\n')
        git(repo, 'add', 'README.md')
        git(repo, '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'base')
        git(repo, 'checkout', '-q', '-b', 'neko/t1')
        return repo, rn.GitTarget(repo, 'neko/t1')

    def commits(self, repo):
        return int(git(repo, 'rev-list', '--count', 'neko/t1').strip())

    def methods(self):
        return [c[0] for c in self.fake.calls]


class LifecycleTests(RunnerBase):
    def test_happy_path_publishes_once(self):
        run = self.start()
        self.assertEqual(run['state'], 'ready')
        manifest = json.loads(run['manifest'])
        self.assertEqual([m['path'] for m in manifest], ['README.md', 'src/app.py'])
        self.assertEqual(len(run['manifest_hash']), 64)
        run = self.service.execute(run['run_id'], self.lease, ['bash', '-lc', 'make'])
        self.assertEqual((run['state'], run['exit_code'], run['cleanup']), ('collected', 0, 'done'))
        self.assertEqual(self.service.verify(run['run_id'])['state'], 'verified')
        repo, target = self.repo()
        self.assertEqual(self.service.publish(run['run_id'], self.lease, target)['state'], 'published')
        self.assertEqual(self.service.publish(run['run_id'], self.lease, target)['state'], 'published')
        self.assertEqual((self.commits(repo), (repo / 'README.md').read_text()), (2, 'new\n'))
        self.assertIn(f"Neko-Run: {run['run_id']}", git(repo, 'log', '-1', '--format=%B'))

    def test_same_attempt_gets_the_same_run_and_one_sandbox(self):
        first, again = self.start(), self.start()
        self.assertEqual(first['run_id'], again['run_id'])
        self.assertEqual(self.methods().count('create'), 1)

    def test_nonzero_exit_collects_before_cleanup(self):
        self.fake.result.update(exit_code=2, log=b'boom\n')
        run = self.service.execute(self.start()['run_id'], self.lease, ['false'])
        self.assertEqual((run['state'], run['detail'], run['cleanup']), ('failed', 'nonzero_exit', 'done'))
        log = (self.store.root / 'tasks' / self.task['id'] / 'runs' / run['run_id'] / 'staging' / 'log.txt').read_bytes()
        self.assertEqual(log, b'boom\n')
        names = self.methods()
        self.assertLess(names.index('collect'), names.index('destroy'))
        with self.assertRaises(rn.RunRefused):
            self.service.verify(run['run_id'])  # a failed run's patch is never published

    def test_time_limit_is_failed_not_success(self):
        self.fake.result.update(exit_code=None, timed_out=True)
        run = self.service.execute(self.start()['run_id'], self.lease, ['sleep', '9999'])
        self.assertEqual((run['state'], run['detail']), ('failed', 'time_limit'))

    def test_sandbox_dead_before_collect_keeps_nothing_and_says_so(self):
        run = self.start()
        self.fake.fail['execute'] = rn.RunnerGone('killed')
        run = self.service.execute(run['run_id'], self.lease, ['make'])
        self.assertEqual((run['state'], run['detail'], run['patch_hash']), ('lost', 'sandbox_gone_during_execute', None))

    def test_unknown_execute_is_never_run_again(self):
        run = self.start()
        self.fake.lose_answer.add('execute')
        run = self.service.execute(run['run_id'], self.lease, ['make'])
        self.assertEqual(run['state'], 'unknown')
        with self.assertRaises(rn.RunRefused):
            self.service.execute(run['run_id'], self.lease, ['make'])
        self.assertEqual(self.methods().count('execute'), 1)

    def test_pause_between_steps(self):
        run = self.start()
        self.assertEqual(self.service.pause(run['run_id'])['paused'], 1)
        self.fake.die(run['sandbox_id'])
        self.assertEqual(self.service.pause(run['run_id'])['cleanup'], 'done')  # a gone sandbox is recorded, not an error


class GuardTests(RunnerBase):
    def test_cancelled_task_stops_the_run_and_frees_the_sandbox(self):
        run = self.start()
        self.store.cancel(self.task['id'])
        with self.assertRaises(rn.RunRefused) as e:
            self.service.execute(run['run_id'], self.lease, ['make'])
        self.assertEqual(e.exception.reason, 'task_stopped')
        run = self.service.run(run['run_id'])
        self.assertEqual((run['state'], run['cleanup']), ('cancelled', 'done'))
        self.assertNotIn('execute', self.methods())

    def test_old_attempt_cannot_publish(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        self.service.verify(run['run_id'])
        with self.store.connect() as c:  # the worker went silent; the task went back to the queue and was claimed again
            c.execute("UPDATE tasks SET status='queued' WHERE id=?", (self.task['id'],))
        renewed = self.store.claim_hands()
        repo, target = self.repo()
        with self.assertRaises(rn.RunRefused) as e:
            self.service.publish(run['run_id'], self.lease, target)
        self.assertEqual(e.exception.reason, 'superseded')
        with self.assertRaises(rn.RunRefused):  # the new attempt does not inherit the old run either
            self.service.publish(run['run_id'], renewed['lease'], target)
        self.assertEqual((self.service.run(run['run_id'])['state'], self.commits(repo)), ('superseded', 1))

    def test_paused_or_locked_office_refuses(self):
        self.store.set_hands_locked(True)
        with self.assertRaises(rn.RunRefused):
            self.start()
        self.assertEqual(self.fake.calls, [])

    def test_over_budget_does_not_start(self):
        with self.assertRaises(rn.RunRefused) as e:
            self.start(limits={'seconds': 100000})
        self.assertEqual((e.exception.reason, self.fake.calls), ('over_budget', []))

    def test_low_disk_does_not_start(self):
        with self.assertRaises(rn.RunRefused) as e:
            self.start(limits={'min_free_bytes': 10 ** 18})
        self.assertEqual(e.exception.reason, 'low_disk')
        self.assertEqual(self.fake.calls, [])

    def test_source_revision_is_required(self):
        with self.assertRaises(rn.RunRefused):
            self.service.start(self.task['id'], self.lease, self.work, ['README.md'], 'main')


class InputTests(RunnerBase):
    def test_secrets_and_unsafe_paths_never_go_in(self):
        (self.work / 'node_modules').mkdir()
        (self.work / 'node_modules' / 'x.js').write_text('x')
        (self.work / 'office.sqlite3').write_text('db')
        (self.work / 'link.md').symlink_to(self.work / '.env')
        for path in ('.env', 'node_modules/x.js', 'office.sqlite3', 'link.md', '../etc/passwd', '/etc/passwd',
                     'src', 'missing.md', 'a\\b', ''):
            with self.assertRaises(rn.RunRefused, msg=path):
                self.start([path])
        self.assertEqual(self.fake.calls, [])

    def test_canary_is_not_in_what_the_sandbox_received(self):
        run = self.start()
        box = self.fake.boxes[run['sandbox_id']]
        self.assertNotIn(CANARY.encode(), b''.join(box['files'].values()))
        self.assertNotIn('.env', box['files'])

    def test_input_changed_after_selection_fails(self):
        original = self.fake.create
        def create(run_id, labels):
            (self.work / 'README.md').write_text('changed underneath\n')
            return original(run_id, labels)
        self.fake.create = create
        run = self.start()
        self.assertEqual((run['state'], run['detail'], run['cleanup']), ('failed', 'input_changed', 'done'))


class PatchTests(RunnerBase):
    def run_with(self, patch):
        self.fake.result['patch'] = patch
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        return self.service.verify(run['run_id'])

    def test_bad_patches_are_rejected(self):
        cases = {
            b'diff --git a/.ssh/config b/.ssh/config\n--- a/.ssh/config\n+++ b/.ssh/config\n': 'patch_excluded_path',
            b'diff --git a/../x b/../x\n--- a/../x\n+++ b/../x\n': 'patch_unsafe_path',
            b'diff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n': 'patch_symlink',
            b'diff --git a/x.bin b/x.bin\nBinary files a/x.bin and b/x.bin differ\n': 'patch_binary_without_content',
            b'diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\n--- a/.github/workflows/ci.yml\n'
            b'+++ b/.github/workflows/ci.yml\n': 'patch_workflow',
            b'diff --git a/a b/a\nrename from a\nrename to .env\n': 'patch_excluded_path',
            b'   \n': 'empty_patch',
        }
        for patch, detail in cases.items():
            with self.subTest(detail=detail):
                self.tearDown(); self.setUp()  # a fresh task per case; the last one is torn down by unittest
                self.assertEqual(self.run_with(patch)['detail'], detail)

    def test_binary_change_is_published_to_the_task_branch(self):
        repo, target = self.repo()
        (repo / 'logo.bin').write_bytes(bytes(range(256)))
        git(repo, 'add', 'logo.bin')
        patch = subprocess.run(['git', '-C', str(repo), 'diff', '--cached', '--binary'], capture_output=True, check=True).stdout
        git(repo, 'rm', '-q', '--cached', 'logo.bin')
        (repo / 'logo.bin').unlink()
        run = self.run_with(patch)
        self.assertEqual(run['state'], 'verified')
        self.assertEqual(self.service.publish(run['run_id'], self.lease, target)['state'], 'published')
        self.assertEqual((repo / 'logo.bin').read_bytes(), bytes(range(256)))
        self.assertEqual(git(repo, 'rev-parse', '--abbrev-ref', 'HEAD').strip(), 'neko/t1')

    def test_too_large_output_is_rejected(self):
        self.fake.result['patch'] = PATCH * 100
        run = self.service.execute(self.start(limits={'output_bytes': 1000})['run_id'], self.lease, ['make'])
        self.assertEqual((run['state'], run['detail']), ('rejected', 'artifact_too_large'))

    def test_staged_patch_changed_on_disk_is_rejected(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        staged = self.store.root / 'tasks' / self.task['id'] / 'runs' / run['run_id'] / 'staging' / 'result.patch'
        staged.write_bytes(PATCH.replace(b'+new', b'+evil'))
        self.assertEqual(self.service.verify(run['run_id'])['detail'], 'patch_changed')


class RecoveryTests(RunnerBase):
    def test_create_answer_lost_then_restart_finds_and_frees_the_sandbox(self):
        self.fake.lose_answer.add('create')
        run = self.start()
        self.assertEqual((run['state'], run['sandbox_id']), ('create_unknown', None))
        moved = rn.RunService(self.store, self.fake).recover()
        run = self.service.run(run['run_id'])
        self.assertEqual((moved[run['run_id']], run['sandbox_id'], run['cleanup']), ('interrupted', 'fake-1', 'done'))
        self.assertEqual(self.fake.boxes['fake-1']['state'], 'gone')  # no leaked sandbox
        self.assertEqual(self.methods().count('create'), 1)

    def test_restart_during_execute_collects_but_never_runs_again(self):
        run = self.start()
        self.service.set(run['run_id'], 'running')
        self.fake.boxes[run['sandbox_id']].update(state='exited', log=b'half\n', patch=PATCH)
        moved = rn.RunService(self.store, self.fake).recover()
        run = self.service.run(run['run_id'])
        self.assertEqual((moved[run['run_id']], run['cleanup']), ('interrupted', 'done'))
        self.assertIsNotNone(run['log_hash'])
        self.assertNotIn('execute', self.methods())
        with self.assertRaises(rn.RunRefused):
            self.service.verify(run['run_id'])  # an interrupted run is not published

    def test_restart_with_sandbox_gone_is_lost(self):
        run = self.start()
        self.service.set(run['run_id'], 'running')
        self.fake.die(run['sandbox_id'])
        self.assertEqual(rn.RunService(self.store, self.fake).recover()[run['run_id']], 'lost')

    def test_restart_when_provider_unreachable_stays_unknown(self):
        run = self.start()
        self.service.set(run['run_id'], 'running')
        self.fake.fail['status'] = rn.RunnerUnknown('no answer')
        self.assertEqual(rn.RunService(self.store, self.fake).recover()[run['run_id']], 'unknown')
        self.assertNotIn('destroy', self.methods())  # not known to be finished: nothing destroyed, nothing rerun

    def ready_to_publish(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        self.service.verify(run['run_id'])
        repo, target = self.repo()
        return run['run_id'], repo, target

    def test_restart_after_commit_landed_marks_published_without_reapplying(self):
        run_id, repo, target = self.ready_to_publish()
        original = target.apply
        def crash_after_commit(rid, patch):
            original(rid, patch)
            raise SystemExit  # the office dies right after the commit, before recording it
        target.apply = crash_after_commit
        with self.assertRaises(SystemExit):
            self.service.publish(run_id, self.lease, target)
        self.assertEqual(self.service.run(run_id)['state'], 'publishing')
        target.apply = original
        moved = rn.RunService(self.store, self.fake).recover(target_for=lambda run: target)
        self.assertEqual((moved[run_id], self.commits(repo)), ('published', 2))
        self.assertEqual(self.service.publish(run_id, self.lease, target)['state'], 'published')
        self.assertEqual(self.commits(repo), 2)

    def test_restart_before_commit_returns_to_verified_and_applies_once(self):
        run_id, repo, target = self.ready_to_publish()
        self.service.set(run_id, 'publishing')  # claimed, then the office died before applying
        moved = rn.RunService(self.store, self.fake).recover(target_for=lambda run: target)
        self.assertEqual(moved[run_id], 'verified')
        self.assertEqual(self.service.publish(run_id, self.lease, target)['state'], 'published')
        self.assertEqual(self.commits(repo), 2)

    def test_restart_without_a_target_leaves_publishing_for_a_person(self):
        run_id, repo, target = self.ready_to_publish()
        self.service.set(run_id, 'publishing')
        self.assertEqual(rn.RunService(self.store, self.fake).recover()[run_id], 'publishing')
        self.assertEqual(self.commits(repo), 1)

    def test_publish_asks_the_branch_before_applying(self):
        run_id, repo, target = self.ready_to_publish()
        target.apply(run_id, PATCH)  # it already landed, but the record still says verified
        self.assertEqual(self.service.publish(run_id, self.lease, target)['state'], 'published')
        self.assertEqual(self.commits(repo), 2)

    def test_patch_changed_after_verify_is_not_applied(self):
        run_id, repo, target = self.ready_to_publish()
        run = self.service.run(run_id)
        staged = self.store.root / 'tasks' / run['task_id'] / 'runs' / run_id / 'staging' / 'result.patch'
        staged.write_bytes(PATCH.replace(b'+new', b'+evil'))
        self.assertEqual(self.service.publish(run_id, self.lease, target)['detail'], 'patch_changed')
        self.assertEqual(self.commits(repo), 1)

    def test_commit_answer_unknown_is_checked_not_repeated(self):
        run_id, repo, target = self.ready_to_publish()
        original = target.apply
        def lose_answer(rid, patch):
            original(rid, patch)
            raise rn.RunnerUnknown('commit did not report success')
        target.apply = lose_answer
        self.assertEqual(self.service.publish(run_id, self.lease, target)['state'], 'published')
        self.assertEqual(self.commits(repo), 2)

    def test_patch_that_does_not_apply_is_not_published(self):
        run_id, repo, target = self.ready_to_publish()
        (repo / 'README.md').write_text('someone else changed this\n')
        git(repo, 'commit', '-qam', 'other change')
        run = self.service.publish(run_id, self.lease, target)
        self.assertEqual((run['state'], run['detail'][:12]), ('verified', 'apply_failed'))
        self.assertNotIn(f'Neko-Run: {run_id}', git(repo, 'log', '--format=%B'))

    def test_cleanup_failure_is_retried_at_restart(self):
        run = self.start()
        self.fake.fail['destroy'] = rn.RunnerUnknown('no answer')
        self.service.set(run['run_id'], 'failed')
        self.assertEqual(self.service.cleanup(run['run_id']), 'failed')
        rn.RunService(self.store, self.fake).recover()
        self.assertEqual(self.service.run(run['run_id'])['cleanup'], 'done')

    def test_task_cancelled_while_office_was_down(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        self.store.cancel(self.task['id'])
        rn.RunService(self.store, self.fake).recover()
        self.assertEqual(self.service.run(run['run_id'])['state'], 'cancelled')


class OfficeWiringTests(RunnerBase):
    """The office owns the run service: it recovers runs at start and shows counts in /api/health."""

    def health(self, office):
        socket_path = self.root / 'run' / 'office.sock'
        server = app.Server(0, office, local_socket=socket_path)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return json.loads(local_request(socket_path, '/api/health')[1])['sandbox']

    def test_without_a_provider_there_are_no_runs(self):
        self.assertIsNone(self.office.runs)
        self.assertEqual(self.health(self.office), {'enabled': False})

    def test_office_start_recovers_a_run_and_never_runs_it_again(self):
        run = self.start()
        self.service.set(run['run_id'], 'running')
        self.fake.boxes[run['sandbox_id']].update(state='exited', log=b'half\n', patch=PATCH)
        office = app.Office(self.store, FakeModel(), sandbox=self.fake)  # the office restarts
        run = office.runs.run(run['run_id'])
        self.assertEqual((run['state'], run['cleanup']), ('interrupted', 'done'))
        self.assertNotIn('execute', self.methods())
        self.assertIn(self.store.get(self.task['id'])['status'], app.ACTIVE)  # the hands task keeps going
        self.assertEqual(self.health(office), {'enabled': True, 'provider': 'fake', 'open': 0, 'needs_person': 0,
                                               'cleanup_failed': 0, 'reachable': None})  # FakeRunner has nothing to probe

    def test_health_counts_what_is_left_for_a_person(self):
        run = self.service.execute(self.start()['run_id'], self.lease, ['make'])
        self.service.verify(run['run_id'])
        self.service.set(run['run_id'], 'publishing')  # the office died mid-publish; no target is wired yet
        office = app.Office(self.store, FakeModel(), sandbox=self.fake)
        self.assertEqual(office.runs.run(run['run_id'])['detail'], 'publish_unknown')
        sandbox = self.health(office)
        self.assertEqual((sandbox['open'], sandbox['needs_person']), (1, 1))
        self.assertNotIn(run['run_id'], json.dumps(sandbox))  # counts only


class TargetTests(RunnerBase):
    def test_branch_name_must_be_a_task_branch(self):
        for name in ('main', 'neko/', 'neko/../main', 'feature/x'):
            with self.assertRaises(ValueError):
                rn.GitTarget(self.root, name)

    def test_wrong_checked_out_branch_is_refused(self):
        repo, target = self.repo()
        git(repo, 'checkout', '-q', '-b', 'other')
        with self.assertRaises(rn.RunnerFailed):
            target.apply('x', PATCH)


if __name__ == '__main__':
    unittest.main()
