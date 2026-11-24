#!/usr/bin/env python3
"""Alternate already-built executables; retain raw JSON and compare observable output.

Build first. Run this script without other builds/benchmarks on the same machine.
On Linux, --cpu pins each measured process to one available logical CPU.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess


def require_matching(left, right, fields, label):
    differing = [field for field in fields if left[field] != right[field]]
    if differing:
        raise RuntimeError(f'{label}: incompatible observations: {", ".join(differing)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--core-baseline', required=True, type=Path)
    parser.add_argument('--core-candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cpu', type=int)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--samples', type=int, default=101)
    args = parser.parse_args()
    if args.repeats < 3 or not 101 <= args.samples <= 2001:
        parser.error('Use at least 3 runs and 101..2001 samples')
    if args.cpu is not None and (not hasattr(os, 'sched_getaffinity') or args.cpu not in os.sched_getaffinity(0)):
        parser.error('--cpu requires an available Linux logical CPU')
    args.output.mkdir(parents=True, exist_ok=True)
    executables = {
        'baseline': args.baseline.resolve(), 'candidate': args.candidate.resolve(),
        'core-baseline': args.core_baseline.resolve(), 'core-candidate': args.core_candidate.resolve(),
    }
    cpu_model = ''
    if Path('/proc/cpuinfo').exists():
        cpu_model = next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), '')
    environment = {
        'platform': platform.platform(), 'cpu_model': cpu_model,
        'affinity_cpu': args.cpu, 'repeats': args.repeats, 'samples': args.samples,
        'binaries': {key: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for key, path in executables.items()},
        'aggregation': 'Median of run medians. p95/p99 are medians of per-run percentiles, not pooled tails.',
        'order': 'Alternate baseline/candidate order each round; rotate architecture order each round.',
        'scope': 'CPU wall time on this host. No X11 transfer, GPU, display/vsync, input-to-display latency, or power measurements.',
    }
    (args.output / 'environment.json').write_text(json.dumps(environment, indent=2) + '\n')
    commands = []

    def run(key, extra, name):
        command = (['taskset', '-c', str(args.cpu)] if args.cpu is not None else []) + [str(executables[key])] + extra
        commands.append(command)
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        report = json.loads(result.stdout)
        (args.output / (name + '.json')).write_text(json.dumps(report, indent=2) + '\n')
        return report

    sizes = {
        '800x600': ['--width', '800', '--height', '600'],
        '1920x1080': ['--width', '1920', '--height', '1080'],
        '1600x1200_scale2': ['--width', '1600', '--height', '1200', '--scale', '2'],
        '1000x750_scale1_25': ['--width', '1000', '--height', '750', '--scale', '1.25'],
    }
    measured = {name: {'baseline': [], 'candidate': []} for name in sizes}
    core = {'baseline': [], 'candidate': []}
    architectures = []
    for round_index in range(args.repeats):
        order = ('baseline', 'candidate') if round_index % 2 == 0 else ('candidate', 'baseline')
        for name, dimensions in sizes.items():
            for key in order:
                measured[name][key].append(run(key, dimensions + ['--samples', str(args.samples)], f'{name}-{key}-{round_index}'))
            a, b = measured[name]['baseline'][-1], measured[name]['candidate'][-1]
            require_matching(a, b, ('width', 'height', 'scale', 'architecture', 'pixel_hash', 'ui_nodes', 'records'), f'{name} output')
            require_matching(a['metadata'], b['metadata'], ('zig', 'optimize', 'arch', 'os', 'cpu_target', 'simd_lanes', 'warmup_frames'), f'{name} build configuration')
            for metric in ('ui', 'software_draw', 'full_cpu_frame', 'idle_scheduler'):
                require_matching(a[metric], b[metric], ('samples', 'iterations_per_sample'), f'{name} {metric} sampling')
            print(f"Round {round_index + 1}, {name}: full CPU frame {a['full_cpu_frame']['median_ns'] / 1e6:.3f} -> {b['full_cpu_frame']['median_ns'] / 1e6:.3f} ms; pixels match", flush=True)
        for key in order:
            core[key].append(run('core-' + key, [], f'core-{key}-{round_index}'))
        require_matching(core['baseline'][-1], core['candidate'][-1], ('zig', 'optimize', 'arch', 'os', 'cpu_target', 'simd_lanes', 'viewport', 'samples', 'warmups'), 'core build and workload')
        for a, b in zip(core['baseline'][-1]['cases'], core['candidate'][-1]['cases'], strict=True):
            require_matching(a, b, ('scene', 'output_hash', 'nodes', 'texts', 'wrapped_runs', 'quads', 'draw_commands'), 'core output')
        architecture_report = run('candidate', ['--architectures', '--architecture-start', str(round_index), '--samples', '501'], f'architectures-{round_index}')
        rows = architecture_report['architectures']
        expected_names = {'viper', 'mvp', 'mvvp', 'mvvm', 'mvvm_c'}
        if len(rows) != len(expected_names) or {row['name'] for row in rows} != expected_names:
            raise RuntimeError('Architecture benchmark omitted or duplicated an architecture')
        for row in rows[1:]:
            require_matching(rows[0], row, ('records', 'ui_nodes', 'checksum'), f'architecture workload {row["name"]}')
            for metric in ('warm_ui', 'changed_filter_ui'):
                require_matching(rows[0][metric], row[metric], ('samples', 'iterations_per_sample'), f'architecture sampling {row["name"]} {metric}')
        if architectures:
            previous = {row['name']: row for row in architectures[0]['architectures']}
            for row in rows:
                require_matching(previous[row['name']], row, ('app_bytes', 'records', 'ui_nodes', 'checksum'), f'architecture repeat {row["name"]}')
        architectures.append(architecture_report)
        (args.output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')

    def stats(values):
        medians = [value['median_ns'] for value in values]
        return {
            'median_ns': statistics.median(medians),
            'run_medians_ns': medians,
            'min_run_median_ns': min(medians),
            'max_run_median_ns': max(medians),
            'median_p95_ns': statistics.median(value['p95_ns'] for value in values),
            'median_p99_ns': statistics.median(value['p99_ns'] for value in values),
        }

    def comparison(a, b):
        result = {'baseline': stats(a), 'candidate': stats(b)}
        result['reduction_percent'] = 100 * (1 - result['candidate']['median_ns'] / result['baseline']['median_ns'])
        return result

    summary = {'environment': environment, 'ui_cases': {}, 'core_cases': {}, 'architectures': {}}
    for name, results in measured.items():
        a, b = results['baseline'], results['candidate']
        all_hashes = {r['pixel_hash'] for r in a + b}
        if len(all_hashes) != 1:
            raise RuntimeError(f'{name}: pixel hash varies across rounds')
        summary['ui_cases'][name] = {
            'pixel_hash': a[0]['pixel_hash'], 'ui_nodes': a[0]['ui_nodes'],
            **{metric: comparison([r[metric] for r in a], [r[metric] for r in b]) for metric in ('ui', 'software_draw', 'full_cpu_frame', 'idle_scheduler')},
        }
    for index in range(len(core['baseline'][0]['cases'])):
        a = [r['cases'][index] for r in core['baseline']]
        b = [r['cases'][index] for r in core['candidate']]
        if len({r['output_hash'] for r in a + b}) != 1:
            raise RuntimeError('Core output hash varies across rounds')
        summary['core_cases'][a[0]['scene']] = {'output_hash': a[0]['output_hash'], **comparison([r['frame'] for r in a], [r['frame'] for r in b])}
    for name in ('viper', 'mvp', 'mvvp', 'mvvm', 'mvvm_c'):
        values = [next(r for r in report['architectures'] if r['name'] == name) for report in architectures]
        summary['architectures'][name] = {
            'app_bytes': values[0]['app_bytes'], 'ui_nodes': values[0]['ui_nodes'],
            'warm_ui': stats([r['warm_ui'] for r in values]),
            'changed_filter_ui': stats([r['changed_filter_ui'] for r in values]),
        }
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Saved raw measurements and summary to', args.output, flush=True)


if __name__ == '__main__':
    main()
