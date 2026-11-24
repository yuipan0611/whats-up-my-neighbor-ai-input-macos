"""H4 offline: push to neko/<task> and Draft PR through a fake GitHub transport (PRD 5.6, ADR-001 A02/A13).

No GitHub App, no network, no real token: FakeGitHub stands in. The worktree is a real git repository
in a temporary folder. Fictional data only."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from test_office import app, FakeModel

sys.path.insert(0, str(Path(__file__).parents[1]))
import github_app as gh  # noqa: E402

REPO = 'owner/test-repo'


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


class PushBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = app.Store(self.root / 'data')
        self.office = app.Office(self.store, FakeModel())
        self.hub = gh.FakeGitHub()
        self.push = gh.GitHubPush(self.store, self.hub)
        self.task = self.office.command({'id': str(uuid.uuid4()), 'prompt': '合成任務：改 README', 'executor': 'hands'})['task']
        self.claimed = self.store.claim_hands()
        self.push.bind(self.task['id'], REPO)
        self.work = self.root / 'work'
        self.work.mkdir()
        git(self.work, 'init', '-q')
        git(self.work, 'config', 'user.name', 'neko-test')
        git(self.work, 'config', 'user.email', 'neko-test@example.test')
        git(self.work, 'config', 'commit.gpgsign', 'false')
        (self.work / 'README.md').write_text('old\n')
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-qm', 'base')
        git(self.work, 'branch', '-M', 'main')
        git(self.work, 'checkout', '-qb', 'work')

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, path='README.md', text='new\n'):
        target = self.work / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-qm', f'change {path}')
        return git(self.work, 'rev-parse', 'HEAD')

    def request(self, **extra):
        return {'task_id': self.task['id'], 'lease': self.claimed['lease'], **extra}

    def call(self, **extra):
        return self.push.push_and_open(self.request(**extra), self.work)

    def refused(self, reason, **extra):
        with self.assertRaises(gh.PushRefused) as e:
            self.call(**extra)
        self.assertEqual(e.exception.reason, reason)

    def branch(self):
        return gh.branch_for(self.task['id'])


class FlowTests(PushBase):
    def test_push_then_draft_pr_and_a_repeat_changes_nothing(self):
        sha = self.commit()
        result = self.call(title='更新 README')
        self.assertEqual((result['push'], result['pr'], result['branch']), ('done', 'done', self.branch()))
        self.assertEqual(self.hub.refs[(REPO, self.branch())], sha)
        pr = self.hub.prs[1]
        self.assertEqual((pr['draft'], pr['base'], pr['head'], pr['title']), (True, 'main', self.branch(), '更新 README'))
        again = self.call()
        names = [m for m, _ in self.hub.calls]
        self.assertEqual((again['pr'], len(self.hub.prs), names.count('push'), names.count('find_pr')), ('done', 1, 1, 1))

    def test_new_commit_pushes_again_but_reuses_the_pr(self):
        self.commit()
        self.call()
        sha2 = self.commit('docs/a.md', 'more\n')
        self.assertEqual(self.call()['pr'], 'done')
        self.assertEqual((self.hub.refs[(REPO, self.branch())], len(self.hub.prs)), (sha2, 1))

    def test_existing_pr_is_found_not_duplicated(self):
        self.commit()
        token = self.hub.token(REPO, True)
        self.hub.create_draft_pr(REPO, self.branch(), 'main', 'opened earlier', '', token)
        self.assertEqual(self.call()['pr'], 'done')
        self.assertEqual(len(self.hub.prs), 1)

    def test_no_token_is_ever_stored_or_returned(self):
        self.commit()
        result = self.call()
        self.assertNotIn('fake-installation-token', repr(result))
        with self.store.connect() as c:
            c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        raw = b''.join(p.read_bytes() for p in (self.root / 'data').glob('office.sqlite3*'))
        self.assertNotIn(b'fake-installation-token', raw)


class RefusalTests(PushBase):
    def test_worker_cannot_choose_repo_branch_refspec_base_or_token(self):
        self.commit()
        for key, value in (('repo', 'owner/other'), ('branch', 'main'), ('refspec', 'HEAD:refs/heads/main'),
                           ('base', 'codex/neko-cicd-updates'), ('token', 'x'), ('tag', 'v1')):
            with self.subTest(key=key):
                self.refused('bad_request', **{key: value})
        self.assertEqual(self.hub.calls, [])

    def test_workflow_changes_are_never_pushed(self):
        self.commit('.github/workflows/build.yml', 'on: push\n')
        self.refused('workflows')
        self.assertEqual(self.hub.calls, [])

    def test_workflow_file_renamed_away_is_also_refused(self):
        self.commit('.github/workflows/build.yml', 'on: push\n')
        git(self.work, 'checkout', '-q', 'main')
        git(self.work, 'merge', '-q', '--ff-only', 'work')
        git(self.work, 'checkout', '-q', 'work')
        git(self.work, 'mv', '.github/workflows/build.yml', 'build.yml')
        git(self.work, 'commit', '-qm', 'move')
        self.refused('workflows')

    def test_one_task_one_repo(self):
        with self.assertRaises(gh.PushRefused) as e:
            self.push.bind(self.task['id'], 'owner/other')
        self.assertEqual(e.exception.reason, 'one_repo')
        for bad in ('../x', 'owner', 'owner/x/y', ''):
            with self.assertRaises(gh.PushRefused):
                self.push.bind(str(uuid.uuid4()), bad)
        with self.assertRaises(gh.PushRefused):
            self.push.bind(str(uuid.uuid4()), REPO, base='neko/abc')

    def test_branch_is_always_the_task_branch(self):
        self.commit()
        self.call()
        self.assertEqual(list(self.hub.refs), [(REPO, f"neko/{self.task['id'][:8]}")])

    def test_stale_lease_cancel_pause_and_lock(self):
        self.commit()
        with self.assertRaises(gh.PushRefused):
            self.push.push_and_open({**self.request(), 'lease': 'not-the-lease'}, self.work)
        self.store.cancel(self.task['id'])
        self.refused('stale_lease')
        self.assertEqual(self.hub.calls, [])

    def test_nothing_new_is_not_pushed(self):
        self.refused('nothing_to_push')

    def test_app_not_installed_on_repo(self):
        self.hub.repos.clear()
        self.commit()
        self.refused('no_token')


class UnknownTests(PushBase):
    def test_lost_push_answer_is_checked_on_the_remote(self):
        self.commit()
        self.hub.lose_answer.add('push')
        self.assertEqual(self.call()['push'], 'done')  # the ref is there: done on evidence, not on the lost answer

    def test_push_already_on_the_remote_is_not_sent_again(self):
        sha = self.commit()
        self.push.write(self.task['id'], 'push', self.branch(), sha, 'intent')  # the office died right after pushing
        self.hub.refs[(REPO, self.branch())] = sha
        self.assertEqual(self.call()['push'], 'done')
        self.assertNotIn('push', [m for m, _ in self.hub.calls])

    def test_push_that_did_not_land_is_unknown_not_success(self):
        self.commit()
        self.hub.fail['push'] = gh.GitHubUnknown('timeout')  # the call never reached GitHub; the remote ref stays empty
        result = self.call()
        self.assertEqual((result['push'], result['pr']), ('unknown', 'not_started'))
        self.assertEqual(self.hub.prs, {})

    def test_lost_pr_answer_is_never_created_again_automatically(self):
        self.commit()
        self.hub.lose_answer.add('create_draft_pr')
        original = self.hub.find_pr
        self.hub.find_pr = lambda *a: None  # GitHub's search has not caught up yet
        self.assertEqual(self.call()['pr'], 'needs_check')
        self.assertEqual(self.call()['pr'], 'needs_check')
        self.assertEqual(len(self.hub.prs), 1)
        self.hub.find_pr = original
        self.assertEqual(self.push.recheck(self.task['id'])['state'], 'done')
        self.assertEqual(self.call()['pr'], 'done')
        self.assertEqual(len(self.hub.prs), 1)

    def test_recheck_absent_allows_one_new_create(self):
        self.commit()
        self.hub.fail['create_draft_pr'] = gh.GitHubUnknown('timeout')  # it really did not happen
        self.assertEqual(self.call()['pr'], 'needs_check')
        self.assertEqual(self.push.recheck(self.task['id'])['state'], 'absent')
        self.assertEqual(self.call()['pr'], 'done')
        self.assertEqual(len(self.hub.prs), 1)

    def test_restart_during_create_becomes_unknown(self):
        self.commit()
        self.push.write(self.task['id'], 'pr', self.branch(), 'branch', 'intent')  # the office died mid-create
        self.assertEqual(gh.GitHubPush(self.store, self.hub).recover(), 1)
        self.hub.find_pr = lambda *a: None
        self.assertEqual(self.call()['pr'], 'needs_check')
        self.assertEqual(self.hub.prs, {})

    def test_definite_failure_is_failed(self):
        self.commit()
        self.hub.fail['push'] = gh.GitHubFailed('protected')
        self.assertEqual(self.call()['push'], 'failed')


class RevokeTests(PushBase):
    def test_revoke_stops_new_pushes_and_lists_what_stays(self):
        self.commit()
        self.call()
        result = self.push.revoke()
        self.assertEqual({e['kind'] for e in result['still_on_github']}, {'push', 'pr'})
        self.assertIn('不會因為收回而消失', result['note'])
        self.commit('b.md', 'x\n')
        self.refused('github_locked')
        self.assertTrue(self.hub.revoked)
        self.assertEqual(self.hub.tokens, {})
        self.assertEqual(len(self.hub.prs), 1)  # nothing claimed undone, nothing deleted


if __name__ == '__main__':
    unittest.main()
