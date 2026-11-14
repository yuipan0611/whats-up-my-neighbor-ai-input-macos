#!/usr/bin/env python3
"""Print a reviewable GCP setup plan; only --apply mutates resources. Never reads an API key."""
import argparse
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPOSITORY = 'yuipan0611/whats-up-my-neighbor-ai-input-macos'


def commands(args):
    project, region, job, bucket = args.project, args.region, args.job, args.bucket
    for value in (project, region, job, bucket):
        if not re.fullmatch(r'[a-z][a-z0-9.-]{2,62}', value):
            raise ValueError('Invalid resource name; use lowercase letters, numbers, hyphens and dots.')
    if not re.fullmatch(r'[a-z][a-z0-9-]{5,19}', job):
        raise ValueError('Job prefix must be 6-20 lowercase letters, numbers and hyphens.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', args.image_tag):
        raise ValueError('Invalid image tag.')
    base = ['gcloud', '--project', project, '--quiet']
    runner = f'{job}-run@{project}.iam.gserviceaccount.com'
    github = f'{job}-github@{project}.iam.gserviceaccount.com'
    builder = f'{job}-build@{project}.iam.gserviceaccount.com'
    secret = job + '-openai'
    image = f'{region}-docker.pkg.dev/{project}/{job}/runner:{args.image_tag}'
    if args.action == 'provision':
        if not re.fullmatch(r'[0-9]{6,20}', args.project_number or ''):
            raise ValueError('provision requires numeric --project-number from projects describe.')
        pool = f'projects/{args.project_number}/locations/global/workloadIdentityPools/{job}'
        condition = ("assertion.repository_id == '1297905701' && assertion.repository_owner_id == '239425700' && "
            "assertion.event_name != 'pull_request' && (assertion.workflow_ref == "
            f"'{REPOSITORY}/.github/workflows/neko-cloud-pilot.yml@refs/heads/codex/neko-cloud-pilot' || "
            f"assertion.workflow_ref == '{REPOSITORY}/.github/workflows/neko-cloud-pilot.yml@refs/heads/main')")
        setup = [base + ['services', 'enable', 'run.googleapis.com', 'cloudbuild.googleapis.com',
            'artifactregistry.googleapis.com', 'storage.googleapis.com', 'iam.googleapis.com',
            'iamcredentials.googleapis.com', 'sts.googleapis.com', 'secretmanager.googleapis.com'],
            base + ['artifacts', 'repositories', 'create', job, '--repository-format=docker', '--location', region],
            base + ['storage', 'buckets', 'create', 'gs://' + bucket, '--location', region,
                    '--uniform-bucket-level-access', '--public-access-prevention']]
        for suffix in ('run', 'github', 'build'):
            setup.append(base + ['iam', 'service-accounts', 'create', job + '-' + suffix])
        for account, role in ((runner, 'roles/storage.objectAdmin'), (github, 'roles/storage.objectAdmin'),
                              (builder, 'roles/storage.objectViewer')):
            setup.append(base + ['storage', 'buckets', 'add-iam-policy-binding', 'gs://' + bucket,
                '--member', 'serviceAccount:' + account, '--role', role])
        setup += [
            base + ['artifacts', 'repositories', 'add-iam-policy-binding', job, '--location', region,
                    '--member', 'serviceAccount:' + builder, '--role', 'roles/artifactregistry.writer'],
            base + ['projects', 'add-iam-policy-binding', project, '--member', 'serviceAccount:' + builder,
                    '--role', 'roles/logging.logWriter', '--condition=None'],
            base + ['projects', 'add-iam-policy-binding', project, '--member', 'serviceAccount:' + github,
                    '--role', 'roles/run.viewer', '--condition=None'],
            base + ['secrets', 'create', secret, '--replication-policy=automatic'],
            base + ['secrets', 'add-iam-policy-binding', secret, '--member', 'serviceAccount:' + runner,
                    '--role', 'roles/secretmanager.secretAccessor'],
            base + ['iam', 'workload-identity-pools', 'create', job, '--location=global',
                    '--display-name=Neko GitHub pilot'],
            base + ['iam', 'workload-identity-pools', 'providers', 'create-oidc', 'github',
                    '--workload-identity-pool', job, '--location=global',
                    '--issuer-uri=https://token.actions.githubusercontent.com',
                    '--attribute-mapping=google.subject=assertion.sub,attribute.repository_id=assertion.repository_id',
                    '--attribute-condition', condition],
            base + ['iam', 'service-accounts', 'add-iam-policy-binding', github,
                    '--member', f'principalSet://iam.googleapis.com/{pool}/attribute.repository_id/1297905701',
                    '--role', 'roles/iam.workloadIdentityUser']]
        return setup
    if args.action in ('check-runtime', 'deploy'):
        build = base + ['builds', 'submit', str(ROOT), '--region', region,
                        '--config', str(ROOT / 'cloudbuild.yaml'), '--substitutions', '_IMAGE=' + image,
                        '--service-account', f'projects/{project}/serviceAccounts/{builder}',
                        '--gcs-source-staging-dir', f'gs://{bucket}/build-source', '--timeout=1200s']
        if args.action == 'check-runtime':
            return [build,
                base + ['run', 'jobs', 'deploy', job + '-probe', '--region', region, '--image', image,
                        '--service-account', runner, '--cpu=2', '--memory=8Gi', '--tasks=1',
                        '--parallelism=1', '--max-retries=0', '--task-timeout=120s',
                        '--command=python3', '--args=/app/codex_adapter.py,--self-check'],
                base + ['run', 'jobs', 'deploy', job + '-audit', '--region', region, '--image', image,
                        '--service-account', runner, '--cpu=1', '--memory=1Gi', '--tasks=1',
                        '--parallelism=1', '--max-retries=0', '--task-timeout=300s',
                        '--set-env-vars', f'RESULTS_BUCKET={bucket},ALLOWED_REPO=https://github.com/{REPOSITORY}'],
                base + ['run', 'jobs', 'add-iam-policy-binding', job + '-probe', '--region', region,
                        '--member', 'serviceAccount:' + github, '--role', 'roles/run.invoker'],
                base + ['run', 'jobs', 'add-iam-policy-binding', job + '-audit', '--region', region,
                        '--member', 'serviceAccount:' + github, '--role', 'roles/run.jobsExecutorWithOverrides'],
                base + ['run', 'jobs', 'execute', job + '-probe', '--region', region, '--wait']]
        if not re.fullmatch(r'[1-9][0-9]*', args.secret_version or ''):
            raise ValueError('deploy requires numeric --secret-version after secure key provisioning.')
        return [build,
                base + ['run', 'jobs', 'deploy', job, '--region', region, '--image', image,
                        '--service-account', runner, '--cpu=2', '--memory=8Gi', '--tasks=1',
                        '--parallelism=1', '--max-retries=0', '--task-timeout=1200s',
                        '--set-env-vars', f'RESULTS_BUCKET={bucket},ALLOWED_REPO=https://github.com/{REPOSITORY}',
                        '--set-secrets', f'/run/private/openai/api-key={secret}:{args.secret_version}'],
                base + ['run', 'jobs', 'add-iam-policy-binding', job, '--region', region,
                        '--member', 'serviceAccount:' + github, '--role', 'roles/run.jobsExecutorWithOverrides']]
    return []


def apply_command(command):
    for attempt in range(8):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            if result.stdout:
                print(result.stdout, end='', flush=True)
            if result.stderr:
                print(result.stderr, end='', file=sys.stderr, flush=True)
            return
        # IAM creation and visibility in other Google APIs are eventually consistent.
        # Only repeat an idempotent binding after this exact propagation error.
        pending_identity = ('add-iam-policy-binding' in command
            and 'Service account ' in result.stderr and 'does not exist' in result.stderr)
        if pending_identity and attempt < 7:
            print('Waiting for the newly created service account to become visible...', flush=True)
            time.sleep(min(2 ** (attempt + 1), 20))
            continue
        if result.stderr:
            print(result.stderr, end='', file=sys.stderr, flush=True)
        raise subprocess.CalledProcessError(result.returncode, command)


def deploy(args):
    planned = commands(args)
    for command in planned:
        print(shlex.join(command), flush=True)
    if not args.apply:
        print('PLAN ONLY. No source, resource or credential was changed.')
        return
    # Fail closed on collisions; never silently adopt another user's resources.
    for command in planned:
        apply_command(command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['provision', 'check-runtime', 'deploy'])
    parser.add_argument('--project', required=True)
    parser.add_argument('--project-number')
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--region', default='us-central1', help='Source and prompts leave the Mac and are processed in the US.')
    parser.add_argument('--job', default='neko-agent')
    parser.add_argument('--image-tag', default='pilot-20261019')
    parser.add_argument('--secret-version', help='Numeric version only; the key itself is never an argument.')
    parser.add_argument('--apply', action='store_true')
    deploy(parser.parse_args())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit('Stopped: ' + str(exc) + '\nNo later step was run. Inspect the failed resource before resuming.')
