#!/usr/bin/env python3
"""USD, checked 2026-10-18. GCP us-central1; CF standard-3 (2 CPU, 8 GiB, 16 GB)."""
import argparse
import json


def estimate(hours, cpu_utilization, free=True, cf_free=True):
    # CF CPU is active usage; memory/disk are provisioned while running.
    cf_cpu_seconds = hours * 3600 * 2 * cpu_utilization
    cf = 5 + max(0, cf_cpu_seconds - (375 * 60 if cf_free else 0)) * .000020
    cf += max(0, hours * 8 - (25 if cf_free else 0)) * 3600 * .0000025
    cf += max(0, hours * 16 - (200 if cf_free else 0)) * 3600 * .00000007
    # GCP Jobs bills allocated CPU and memory for the whole task attempt, including I/O waits.
    cpu_free, memory_free = (240000, 450000) if free else (0, 0)
    gcp = max(0, hours * 3600 * 2 - cpu_free) * .000018
    gcp += max(0, hours * 3600 * 8 - memory_free) * .000002
    return {'running_hours': hours, 'cloudflare_cpu_utilization': cpu_utilization,
            'cloudflare_subscription_and_container_usd': round(cf, 4),
            'gcp_jobs_compute_usd': round(gcp, 4), 'gcp_free_tier_available': free}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hours', type=float, default=60)
    parser.add_argument('--cpu-utilization', type=float, default=.2)
    parser.add_argument('--no-gcp-free-tier', action='store_true')
    parser.add_argument('--no-cloudflare-included-usage', action='store_true')
    parser.add_argument('--tasks', type=int, default=0)
    parser.add_argument('--input-tokens', type=int, default=0)
    parser.add_argument('--output-tokens', type=int, default=0)
    parser.add_argument('--input-price-per-million', type=float)
    parser.add_argument('--output-price-per-million', type=float)
    args = parser.parse_args()
    if args.hours < 0 or not 0 <= args.cpu_utilization <= 1 or min(args.tasks, args.input_tokens, args.output_tokens,
            args.input_price_per_million or 0, args.output_price_per_million or 0) < 0:
        parser.error('Inputs must be nonnegative; CPU utilization must be between 0 and 1.')
    result = estimate(args.hours, args.cpu_utilization, not args.no_gcp_free_tier, not args.no_cloudflare_included_usage)
    result['model_cost_usd_using_your_prices'] = (round(args.tasks * (
        args.input_tokens * args.input_price_per_million + args.output_tokens * args.output_price_per_million) / 1e6, 4)
        if args.input_price_per_million is not None and args.output_price_per_million is not None else None)
    result['excluded'] = ['control-plane overages', 'persistent storage', 'builds', 'registry',
                          'network', 'tax', 'paid/private macOS CI', 'retries and startup overhead not in hours']
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
