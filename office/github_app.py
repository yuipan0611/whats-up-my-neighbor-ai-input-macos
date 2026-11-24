"""H4 offline: the office pushes a hands task's commits to neko/<task> and opens a Draft PR (PRD 5.6, ADR-001 A02/A13).

The worker only asks: `{task_id, lease}`. Repository, branch, refspec, base and token are all decided
here, on the control side; the hands never hold a GitHub key. Before anything leaves:
1. the task is still the active attempt and the lease is current;
2. the push touches the one repository configured for that task;
3. no change under .github/workflows/;
4. the refspec is HEAD:refs/heads/neko/<task short id>.
The office never merges, deletes branches or tags.

External effects are written down before they are attempted and settled only on evidence: a push is
checked against the remote ref, a PR is looked up by its head branch before one is created. A PR whose
creation answer was lost stays `unknown` and is never created again automatically; a person rechecks.
Revoking stops new tokens and invalidates issued ones; it does not undo what was already pushed or
opened, and says so.

Only a fake transport exists so far. A real GitHub App transport (installation tokens, RS256 JWT) is
not written and no App exists. Python standard library only."""
from __future__ import annotations
import hmac
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ACTIVE = ('planning', 'running', 'saving')
REPO = re.compile(r'[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}')
SCHEMA = '''
CREATE TABLE IF NOT EXISTS github_tasks (task_id TEXT PRIMARY KEY, repo TEXT NOT NULL, base TEXT NOT NULL, created TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS github_effects (task_id TEXT NOT NULL, kind TEXT NOT NULL, branch TEXT NOT NULL, sha TEXT NOT NULL,
    state TEXT NOT NULL, external_ref TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '', created TEXT NOT NULL,
    updated TEXT NOT NULL, PRIMARY KEY (task_id, kind, sha));
INSERT OR IGNORE INTO settings VALUES ('github_locked', '0');
'''
FORBIDDEN_PREFIXES = ('.github/workflows/',)


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


class GitHubUnknown(Exception):
    """Timeout or lost connection: whether GitHub acted is not known."""


class GitHubFailed(Exception):
    """GitHub answered with a definite refusal: nothing changed."""


class PushRefused(Exception):
    def __init__(self, reason, message, status=409):
        super().__init__(message)
        self.reason, self.status = reason, status


def branch_for(task_id):
    return f'neko/{task_id[:8]}'


class FakeGitHub:
    """In memory, one installation. Tokens are opaque strings that only this object understands."""

    def __init__(self, repos=('owner/test-repo',)):
        self.repos, self.refs, self.prs, self.calls = set(repos), {}, {}, []
        self.tokens, self.revoked, self.lose_answer, self.fail = {}, False, set(), {}

    def _use(self, method, token, repo, write):
        self.calls.append((method, repo))
        if method in self.fail:
            raise self.fail.pop(method)
        grant = self.tokens.get(token)
        if grant is None or grant['repo'] != repo or (write and not grant['write']):
            raise GitHubFailed('token not valid for this')
        if repo not in self.repos:
            raise GitHubFailed('app not installed on this repository')

    def token(self, repo, write):
        if self.revoked:
            raise GitHubFailed('app access revoked')
        if repo not in self.repos:
            raise GitHubFailed('app not installed on this repository')
        value = f'fake-installation-token-{len(self.tokens) + 1:04d}'
        self.tokens[value] = {'repo': repo, 'write': write}
        return value

    def remote_ref(self, repo, branch, token):
        self._use('remote_ref', token, repo, False)
        return self.refs.get((repo, branch))

    def push(self, repo, worktree, sha, branch, token):
        self._use('push', token, repo, True)
        if not branch.startswith('neko/'):
            raise GitHubFailed('protected ref')
        self.refs[(repo, branch)] = sha
        if 'push' in self.lose_answer:
            self.lose_answer.discard('push')
            raise GitHubUnknown('push timed out')

    def find_pr(self, repo, head, token):
        self._use('find_pr', token, repo, False)
        return next((pr for pr in self.prs.values() if pr['repo'] == repo and pr['head'] == head and pr['state'] == 'open'), None)

    def create_draft_pr(self, repo, head, base, title, body, token):
        self._use('create_draft_pr', token, repo, True)
        number = len(self.prs) + 1
        self.prs[number] = {'number': number, 'repo': repo, 'head': head, 'base': base, 'title': title,
                            'draft': True, 'state': 'open', 'url': f'https://github.example/{repo}/pull/{number}'}
        if 'create_draft_pr' in self.lose_answer:
            self.lose_answer.discard('create_draft_pr')
            raise GitHubUnknown('create timed out')
        return self.prs[number]

    def revoke_all(self):
        self.revoked = True
        self.tokens.clear()


class GitHubPush:
    def __init__(self, store, transport):
        self.store, self.transport = store, transport
        with store.connect() as c:
            c.executescript(SCHEMA)

    # -- set up by the owner side when the task is created, never by the worker -----------------

    def bind(self, task_id, repo, base='main'):
        if not REPO.fullmatch(repo or '') or '..' in repo:
            raise PushRefused('bad_repo', 'repo 格式不正確。', 400)
        if not re.fullmatch(r'[A-Za-z0-9._/-]{1,100}', base) or base.startswith('neko/'):
            raise PushRefused('bad_base', 'base 分支不正確。', 400)
        with self.store.connect() as c:
            existing = c.execute('SELECT repo,base FROM github_tasks WHERE task_id=?', (task_id,)).fetchone()
            if existing and (existing['repo'], existing['base']) != (repo, base):
                raise PushRefused('one_repo', '一件工作只碰一個 repo。')
            c.execute('INSERT OR IGNORE INTO github_tasks VALUES (?,?,?,?)', (task_id, repo, base, now()))

    # -- checks ---------------------------------------------------------------------------------

    def guard(self, request):
        if not isinstance(request, dict) or set(request) - {'task_id', 'lease', 'title'} or not {'task_id', 'lease'} <= set(request):
            # A worker that names a repo, branch, refspec, base or token is refused outright.
            raise PushRefused('bad_request', '只接受 task_id、lease 與 title。', 400)
        task_id, lease = request['task_id'], request['lease']
        if not all(isinstance(v, str) and v for v in (task_id, lease)):
            raise PushRefused('bad_request', 'task_id 與 lease 需為字串。', 400)
        title = request.get('title', '')
        if not isinstance(title, str) or len(title) > 120 or any(ord(ch) < 32 for ch in title):
            raise PushRefused('bad_request', 'title 需為 120 字以內的一行字。', 400)
        with self.store.connect() as c:
            task = c.execute('SELECT status,executor,lease,prompt FROM tasks WHERE id=?', (task_id,)).fetchone()
            stopped = c.execute("SELECT key FROM settings WHERE key IN ('paused','hands_locked','github_locked') AND value='1'").fetchone()
            bound = c.execute('SELECT repo,base FROM github_tasks WHERE task_id=?', (task_id,)).fetchone()
        if task is None or task['executor'] != 'hands':
            raise PushRefused('unknown_task', '找不到這件工作。', 404)
        if task['status'] not in ACTIVE or not hmac.compare_digest(task['lease'].encode(), lease.encode()):
            raise PushRefused('stale_lease', '這件工作已經停止或交給新的一輪。')
        if stopped:
            raise PushRefused(stopped['key'], '辦公室暫停中或已收回權限。')
        if bound is None:
            raise PushRefused('no_repo', '這件工作沒有設定 repo。')
        return task_id, bound['repo'], bound['base'], title or task['prompt'][:60]

    @staticmethod
    def git(worktree, *args):
        out = subprocess.run(['git', '-C', str(worktree), *args], capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            raise PushRefused('git_failed', '讀不到工作區的 git 狀態。')
        return out.stdout.strip()

    def inspect(self, worktree, base):
        sha = self.git(worktree, 'rev-parse', '--verify', 'HEAD^{commit}')
        merge_base = self.git(worktree, 'merge-base', base, sha)
        if merge_base == sha:
            raise PushRefused('nothing_to_push', '沒有新的 commit。')
        # --no-renames lists a moved file as a deletion plus an addition, so both old and new paths are checked.
        changed = self.git(worktree, 'diff', '--name-only', '--no-renames', f'{merge_base}..{sha}').splitlines()
        if any(p.startswith(FORBIDDEN_PREFIXES) for p in changed):
            raise PushRefused('workflows', '這次改動碰到 .github/workflows/，辦公室不代推。')
        return sha

    # -- effects ----------------------------------------------------------------------------------

    def effect(self, c, task_id, kind, sha):
        return c.execute('SELECT * FROM github_effects WHERE task_id=? AND kind=? AND sha=?', (task_id, kind, sha)).fetchone()

    def write(self, task_id, kind, branch, sha, state, external_ref='', detail=''):
        with self.store.connect() as c:
            c.execute('INSERT INTO github_effects(task_id,kind,branch,sha,state,external_ref,detail,created,updated) '
                      'VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(task_id,kind,sha) DO UPDATE SET state=excluded.state,'
                      'external_ref=excluded.external_ref,detail=excluded.detail,updated=excluded.updated',
                      (task_id, kind, branch, sha, state, external_ref, detail, now(), now()))

    def push_and_open(self, request, worktree):
        """POST /api/worker/push. Safe to call again: a repeated call resumes from what is recorded."""
        task_id, repo, base, title = self.guard(request)
        sha = self.inspect(Path(worktree), base)
        branch = branch_for(task_id)
        try:
            token = self.transport.token(repo, write=True)  # one hour, this repository only; never stored or returned
        except GitHubFailed:
            raise PushRefused('no_token', '拿不到這個 repo 的臨時鑰匙（App 沒裝或已收回）。')
        except GitHubUnknown:
            raise PushRefused('no_token', '暫時拿不到臨時鑰匙，稍後再試。', 503)
        pushed = self.push(task_id, repo, branch, sha, Path(worktree), token)
        if pushed != 'done':
            return {'push': pushed, 'pr': 'not_started', 'branch': branch}
        pr = self.open_pr(task_id, repo, branch, base, sha, title, token)
        return {'push': 'done', 'pr': pr['state'], 'branch': branch, 'pr_url': pr.get('url', '')}

    def push(self, task_id, repo, branch, sha, worktree, token):
        with self.store.connect() as c:
            row = self.effect(c, task_id, 'push', sha)
        if row and row['state'] == 'done':
            return 'done'
        try:
            if self.transport.remote_ref(repo, branch, token) == sha:  # already there (an earlier answer was lost)
                self.write(task_id, 'push', branch, sha, 'done', detail='found_on_remote')
                return 'done'
        except GitHubUnknown:
            self.write(task_id, 'push', branch, sha, 'unknown', detail='remote_ref_unknown')
            return 'unknown'
        self.write(task_id, 'push', branch, sha, 'intent')  # before the call: a crash leaves something to check
        try:
            self.transport.push(repo, worktree, sha, branch, token)
        except GitHubFailed as e:
            self.write(task_id, 'push', branch, sha, 'failed', detail=str(e)[:120])
            return 'failed'
        except GitHubUnknown:
            try:
                landed = self.transport.remote_ref(repo, branch, token) == sha
            except GitHubUnknown:
                landed = None
            if not landed:
                # Pushing the same commit to the task's own branch again is harmless, so a later call may retry;
                # it is still not reported as done.
                self.write(task_id, 'push', branch, sha, 'unknown', detail='push_unknown')
                return 'unknown'
        self.write(task_id, 'push', branch, sha, 'done')
        return 'done'

    def open_pr(self, task_id, repo, branch, base, sha, title, token):
        with self.store.connect() as c:
            row = self.effect(c, task_id, 'pr', 'branch')  # one PR per task branch, whatever the commit
        if row and row['state'] == 'done':
            return {'state': 'done', 'url': row['external_ref']}
        if row and row['state'] in ('unknown', 'intent'):
            # The last create may have worked. Look, but never create again without a person.
            try:
                found = self.transport.find_pr(repo, branch, token)
            except GitHubUnknown:
                found = None
            if found:
                self.write(task_id, 'pr', branch, 'branch', 'done', found['url'], 'found_after_unknown')
                return {'state': 'done', 'url': found['url']}
            return {'state': 'needs_check'}
        try:
            found = self.transport.find_pr(repo, branch, token)
        except GitHubUnknown:
            return {'state': 'unknown'}  # nothing attempted yet; nothing recorded as an effect
        if found:
            self.write(task_id, 'pr', branch, 'branch', 'done', found['url'], 'existing_pr')
            return {'state': 'done', 'url': found['url']}
        self.write(task_id, 'pr', branch, 'branch', 'intent')
        body = f'由貓咪的工作 {task_id[:8]} 產生。Draft；請人審閱後再決定。'
        try:
            pr = self.transport.create_draft_pr(repo, branch, base, title, body, token)
        except GitHubFailed as e:
            self.write(task_id, 'pr', branch, 'branch', 'failed', detail=str(e)[:120])
            return {'state': 'failed'}
        except GitHubUnknown:
            self.write(task_id, 'pr', branch, 'branch', 'unknown', detail='create_unknown')
            return {'state': 'needs_check'}
        self.write(task_id, 'pr', branch, 'branch', 'done', pr['url'])
        return {'state': 'done', 'url': pr['url']}

    # -- owner side ---------------------------------------------------------------------------------

    def recheck(self, task_id):
        """A person asks the office to look again for a PR whose creation is unknown. Found: done.
        Not found: the unknown is cleared, so the next push call may create one."""
        with self.store.connect() as c:
            row = self.effect(c, task_id, 'pr', 'branch')
            bound = c.execute('SELECT repo FROM github_tasks WHERE task_id=?', (task_id,)).fetchone()
        if row is None or row['state'] not in ('unknown', 'intent') or bound is None:
            raise PushRefused('nothing_to_check', '沒有待核對的 PR。')
        token = self.transport.token(bound['repo'], write=False)
        found = self.transport.find_pr(bound['repo'], row['branch'], token)
        if found:
            self.write(task_id, 'pr', row['branch'], 'branch', 'done', found['url'], 'found_on_recheck')
            return {'state': 'done', 'url': found['url']}
        with self.store.connect() as c:
            c.execute("DELETE FROM github_effects WHERE task_id=? AND kind='pr' AND sha='branch' AND state IN ('unknown','intent')",
                      (task_id,))
        return {'state': 'absent'}

    def revoke(self):
        """The key list's 'take back': no new tokens from now on, issued ones invalidated. What already
        reached GitHub stays there and is listed, never reported as undone."""
        with self.store.connect() as c:
            c.execute("UPDATE settings SET value='1' WHERE key='github_locked'")
        self.transport.revoke_all()
        with self.store.connect() as c:
            left = [dict(r) for r in c.execute("SELECT task_id,kind,branch,state,external_ref FROM github_effects "
                                               "WHERE state IN ('done','unknown','intent') ORDER BY created")]
        return {'revoked': True, 'still_on_github': left,
                'note': '已推上去的分支和已開的 Draft PR 不會因為收回而消失，需要的話請到 GitHub 處理。'}

    def recover(self):
        """At start: a push or PR left at intent may have happened. It becomes unknown, to be checked."""
        with self.store.connect() as c:
            return c.execute("UPDATE github_effects SET state='unknown',detail='restart_during_effect',updated=? "
                             "WHERE state='intent'", (now(),)).rowcount
