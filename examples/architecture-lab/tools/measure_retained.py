#!/usr/bin/env python3
"""Measure already-built incremental/reuse binaries and preserve correctness evidence.

Run with no other builds or benchmarks on the host. --cpu pins every child on Linux.
The default five repeats give one extra baseline-first run; an even count, such as
four, balances the two orders exactly. At least three repeats are required.
No X11 transport or display latency is measured. Payload bytes are calculated.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess


SIZES = (
    ('800x600', 800, 600, 1.0),
    ('1000x750_scale1_25', 1000, 750, 1.25),
    ('1920x1080', 1920, 1080, 1.0),
)
INCREMENTAL_SCENARIOS = {
    'unchanged', 'hover', 'selection', 'scroll', 'theme', 'navigation',
    'sidebar', 'invalidation',
}
REUSE_SCENARIOS = {'unchanged', 'ancestor_clip', 'ancestor_layout', 'mixed_updates'}
INCREMENTAL_TIMINGS = {'ui', 'full_draw', 'incremental_draw'}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def require_matching(left, right, fields, label):
    different = [field for field in fields if left[field] != right[field]]
    require(not different, f'{label}: fields differ: {", ".join(different)}')


def without(mapping, *fields):
    return {key: value for key, value in mapping.items() if key not in fields}


def cases_by_key(report, retained=False):
    rows = report['cases']
    keys = [(row['rows'], row['scenario']) if retained else row['scenario'] for row in rows]
    require(len(set(keys)) == len(keys), 'Duplicate benchmark case')
    expected = ({(rows, scenario) for rows in (330, 1320) for scenario in REUSE_SCENARIOS}
                if retained else INCREMENTAL_SCENARIOS)
    require(set(keys) == expected, f'Missing or unexpected cases: {set(keys) ^ expected}')
    return dict(zip(keys, rows, strict=True))


def timing_stats(values):
    for value in values:
        require(0 < value['median_ns'] <= value['p95_ns'] <= value['p99_ns'],
                f'Invalid timing percentiles: {value}')
    medians = [value['median_ns'] for value in values]
    result = {
        'median_ns': statistics.median(medians),
        'run_medians_ns': medians,
        'min_run_median_ns': min(medians),
        'max_run_median_ns': max(medians),
        'median_p95_ns': statistics.median(value['p95_ns'] for value in values),
        'median_p99_ns': statistics.median(value['p99_ns'] for value in values),
    }
    if all('min_ns' in value and 'max_ns' in value for value in values):
        result['min_sample_ns'] = min(value['min_ns'] for value in values)
        result['max_sample_ns'] = max(value['max_ns'] for value in values)
    return result


def comparison(before, after, before_label, after_label):
    return {
        'before_label': before_label,
        'after_label': after_label,
        'before': before,
        'after': after,
        'reduction_percent': 100 * (1 - after['median_ns'] / before['median_ns']),
        'speedup': before['median_ns'] / after['median_ns'],
    }


def validate_incremental(report, size, samples, previous=None):
    name, width, height, scale = size
    require((report['width'], report['height'], report['scale']) == (width, height, scale),
            f'{name}: binary measured a different size/scale')
    metadata = report['metadata']
    require(metadata['samples'] == samples, f'{name}: sample count differs')
    full_pixels = width * height
    require(report['full_pixel_payload_bytes'] == full_pixels * 4, f'{name}: bad full payload')
    rows = cases_by_key(report)
    previous_rows = cases_by_key(previous) if previous is not None else None
    if previous is not None:
        require_matching(report, previous, ('metadata', 'width', 'height', 'scale', 'full_pixel_payload_bytes'),
                         f'{name}: repeat metadata')
    for scenario, row in rows.items():
        label = f'{name}/{scenario}'
        require(row['verified_frames'] == samples + metadata['warmup_frames'],
                f'{label}: not every warmup/measured frame was checked')
        for field in ('full_frames', 'glyph_rebuild_frames', 'changed_pixel_frames', 'zero_damage_frames'):
            require(0 <= row[field] <= samples, f'{label}: invalid {field}')
        active_frames = samples - row['zero_damage_frames']
        require(row['changed_pixel_frames'] <= active_frames and row['full_frames'] <= active_frames,
                f'{label}: changed/full frames cannot have zero damage')
        require(0 <= row['mean_damage_pixels'] <= full_pixels, f'{label}: invalid damage area')
        require(4 * row['mean_damage_pixels'] <= row['mean_pixel_payload_bytes'] <=
                min(full_pixels * 4, 4 * row['mean_damage_pixels'] + 3),
                f'{label}: incompatible rounded damage/payload means')
        if scenario == 'unchanged':
            require(row['changed_pixel_frames'] == 0 and row['zero_damage_frames'] == samples and
                    row['full_frames'] == 0 and row['glyph_rebuild_frames'] == 0 and
                    row['mean_pixel_payload_bytes'] == 0, f'{label}: static work did not settle')
        elif scenario == 'invalidation':
            require(row['changed_pixel_frames'] == 0 and row['full_frames'] == samples and
                    row['glyph_rebuild_frames'] == samples and row['mean_damage_pixels'] == full_pixels,
                    f'{label}: explicit invalidation did not force complete redraws')
        else:
            require(row['changed_pixel_frames'] > 0 and active_frames > 0,
                    f'{label}: changing scenario became a no-op')
        for field in INCREMENTAL_TIMINGS:
            timing_stats([row[field]])
        if previous_rows is not None:
            require(without(row, *INCREMENTAL_TIMINGS) == without(previous_rows[scenario], *INCREMENTAL_TIMINGS),
                    f'{label}: sequence hash, damage, or counters vary across repeats')
    return rows


def validate_reuse(report, candidate, previous=None):
    label = 'candidate' if candidate else 'baseline'
    rows = cases_by_key(report, retained=True)
    previous_rows = cases_by_key(previous, retained=True) if previous is not None else None
    if previous is not None:
        require(without(report, 'cases') == without(previous, 'cases'),
                f'{label}: reuse metadata varies across repeats')
    total_frames = report['warmups'] + report['samples']
    for key, row in rows.items():
        case_label = f'{label}/{key[0]}/{key[1]}'
        require(row['compared_frames'] == total_frames, f'{case_label}: incomplete per-frame comparison')
        require(row['same_output_and_updates'] == (row['mismatched_frames'] == 0),
                f'{case_label}: inconsistent match flag')
        require((row['first_mismatch_step'] is None) == (row['mismatched_frames'] == 0),
                f'{case_label}: inconsistent first mismatch')
        require(0 <= row['mismatched_frames'] <= total_frames, f'{case_label}: invalid mismatch count')
        if row['first_mismatch_step'] is not None:
            require(0 <= row['first_mismatch_step'] < total_frames, f'{case_label}: invalid mismatch step')
        if candidate:
            require(row['same_output_and_updates'], f'{case_label}: optimized reuse changed semantics')
        full = row['full_rebuild']
        retained = row['retained']
        if row['same_output_and_updates']:
            require(full['sequence_hash'] == retained['sequence_hash'],
                    f'{case_label}: matching observations have different sequence digests')
        require(full['subtree_copies'] == 0 and full['subtree_builds'] == total_frames,
                f'{case_label}: full control skipped work')
        if row['scenario'] != 'unchanged':
            require(full['changed_output_frames'] > 0, f'{case_label}: changing control became a no-op')
        if row['scenario'] == 'mixed_updates':
            require(full['timer_fires'] > 0 and full['keyboard_activations'] > 0,
                    f'{case_label}: mixed input did not exercise timer/keyboard work')
        for mode in ('full_rebuild', 'retained'):
            value = row[mode]
            require(value['observed_frames'] == total_frames, f'{case_label}/{mode}: missing observations')
            require(value['subtree_builds'] + value['subtree_copies'] == total_frames,
                    f'{case_label}/{mode}: missing build/copy work')
            require(0 <= value['changed_output_frames'] <= report['samples'],
                    f'{case_label}/{mode}: invalid changed-frame count')
            timing_stats([value['frame']])
            if previous_rows is not None:
                require(without(value, 'frame') == without(previous_rows[key][mode], 'frame'),
                        f'{case_label}/{mode}: sequence hash or counters vary across repeats')
        if previous_rows is not None:
            require(without(row, 'full_rebuild', 'retained', 'run_order') ==
                    without(previous_rows[key], 'full_rebuild', 'retained', 'run_order'),
                    f'{case_label}: mismatch evidence varies across repeats')
    return rows


def aggregate_incremental(reports):
    first = reports[0]
    indexed = [cases_by_key(report) for report in reports]
    result = {
        'width': first['width'], 'height': first['height'], 'scale': first['scale'],
        'metadata': first['metadata'], 'retained_bytes': first['metadata']['retained_bytes'],
        'full_pixel_payload_bytes': first['full_pixel_payload_bytes'], 'cases': {},
    }
    for scenario, row in indexed[0].items():
        value = without(row, *INCREMENTAL_TIMINGS)
        value.update({field: timing_stats([cases[scenario][field] for cases in indexed])
                      for field in INCREMENTAL_TIMINGS})
        value['draw_comparison'] = comparison(value['full_draw'], value['incremental_draw'],
                                              'forced full draw', 'incremental draw')
        value['pixel_payload_reduction_percent'] = 100 * (
            1 - row['mean_pixel_payload_bytes'] / first['full_pixel_payload_bytes'])
        result['cases'][scenario] = value
    return result


def aggregate_reuse(reports):
    indexed = {label: [cases_by_key(report, retained=True) for report in runs]
               for label, runs in reports.items()}
    result = {
        'metadata': {label: without(runs[0], 'cases') for label, runs in reports.items()},
        'cases': {},
    }
    for key, candidate_row in indexed['candidate'][0].items():
        value = {'rows': key[0], 'scenario': key[1], 'compared_frames': candidate_row['compared_frames']}
        for label in ('baseline', 'candidate'):
            case_runs = [cases[key] for cases in indexed[label]]
            reference = case_runs[0]
            valid = reference['same_output_and_updates']
            modes = {}
            for mode in ('full_rebuild', 'retained'):
                timing_valid = mode == 'full_rebuild' or valid
                modes[mode] = {
                    **without(reference[mode], 'frame'),
                    'timing_valid': timing_valid,
                    'frame': timing_stats([case[mode]['frame'] for case in case_runs]) if timing_valid else None,
                }
                if not timing_valid:
                    modes[mode]['invalid_reason'] = (
                        'Retained work differs from its full control. Timings remain in the raw JSON '
                        'and are excluded from summary timing comparisons.')
            value[label] = {
                'same_output_and_updates': valid,
                'mismatched_frames': reference['mismatched_frames'],
                'first_mismatch_step': reference['first_mismatch_step'],
                'run_orders': [case['run_order'] for case in case_runs],
                **modes,
            }
        before, after = value['baseline'], value['candidate']
        value['full_rebuild_comparison'] = comparison(before['full_rebuild']['frame'], after['full_rebuild']['frame'],
                                                      'baseline full rebuild', 'candidate full rebuild')
        value['candidate_reuse_comparison'] = comparison(after['full_rebuild']['frame'], after['retained']['frame'],
                                                         'candidate full rebuild', 'candidate retained')
        value['retained_version_comparison'] = (
            comparison(before['retained']['frame'], after['retained']['frame'],
                       'baseline retained', 'candidate retained')
            if before['same_output_and_updates'] else None)
        result['cases'][f'{key[0]}_{key[1]}'] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--incremental', required=True, type=Path)
    parser.add_argument('--reuse-baseline', required=True, type=Path)
    parser.add_argument('--reuse-candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cpu', type=int)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--samples', type=int, default=101,
                        help='Incremental samples per scenario; reuse reports its fixed sample count')
    args = parser.parse_args()
    if args.repeats < 3 or not 101 <= args.samples <= 2001:
        parser.error('Use at least 3 repeats and 101..2001 incremental samples')
    if args.cpu is not None and (not hasattr(os, 'sched_getaffinity') or args.cpu not in os.sched_getaffinity(0)):
        parser.error('--cpu requires an available Linux logical CPU')
    executables = {
        'incremental': args.incremental.resolve(),
        'reuse-baseline': args.reuse_baseline.resolve(),
        'reuse-candidate': args.reuse_candidate.resolve(),
    }
    for label, path in executables.items():
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f'{label}: not an executable file: {path}')
    args.output.mkdir(parents=True, exist_ok=True)
    cpuinfo = Path('/proc/cpuinfo')
    cpu_model = next((line.split(':', 1)[1].strip() for line in cpuinfo.read_text().splitlines()
                      if line.startswith('model name')), '') if cpuinfo.exists() else ''
    environment = {
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'platform': platform.platform(), 'python': platform.python_version(), 'cpu_model': cpu_model,
        'affinity_cpu': args.cpu, 'repeats': args.repeats, 'incremental_samples': args.samples,
        'binaries': {label: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                     for label, path in executables.items()},
        'aggregation': 'Median of run medians and their range; p95/p99 are medians of per-run percentiles, not pooled tails.',
        'order': 'Rotate incremental size order; alternate reuse baseline/candidate process order and --retained-first every round.',
        'reuse_baseline_first_runs': (args.repeats + 1) // 2,
        'reuse_candidate_first_runs': args.repeats // 2,
        'retained_first_flag_runs': args.repeats // 2,
        'order_balance': 'Odd repeat counts leave one extra initial-order run; even counts balance the two orders exactly.',
        'scope': 'CPU wall time. No X11 transfer, GPU, vsync, input-to-display latency or power measurement. Payload bytes are calculated.',
        'validity': 'All candidate reuse frames must match their full control. Both versions must share full-control sequence digests. Invalid baseline retained timings are kept only in raw reports.',
    }
    write_json(args.output / 'environment.json', environment)
    commands = []

    def run(label, extra, name, round_index):
        command = (['taskset', '-c', str(args.cpu)] if args.cpu is not None else []) + [str(executables[label])] + extra
        commands.append({'round': round_index, 'binary': label, 'command': command, 'report': name + '.json'})
        write_json(args.output / 'commands.json', commands)
        process = subprocess.run(command, text=True, capture_output=True, check=False)
        (args.output / (name + '.json')).write_text(process.stdout)
        if process.stderr:
            (args.output / (name + '.stderr.txt')).write_text(process.stderr)
        require(process.returncode == 0, f'{name}: exit {process.returncode}; inspect saved stdout/stderr')
        try:
            return json.loads(process.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(f'{name}: invalid JSON; raw stdout was preserved') from error

    incremental = {size[0]: [] for size in SIZES}
    reuse = {'baseline': [], 'candidate': []}
    for round_index in range(args.repeats):
        offset = round_index % len(SIZES)
        for size in SIZES[offset:] + SIZES[:offset]:
            name, width, height, scale = size
            report = run('incremental', [str(args.samples), str(width), str(height), str(scale)],
                         f'incremental-{name}-{round_index}', round_index)
            validate_incremental(report, size, args.samples, incremental[name][0] if incremental[name] else None)
            incremental[name].append(report)
            print(f'Round {round_index + 1}: incremental {name}, all changing cases active and pixels verified', flush=True)
        order = ('baseline', 'candidate') if round_index % 2 == 0 else ('candidate', 'baseline')
        extra = ['--retained-first'] if round_index % 2 != 0 else []
        for label in order:
            report = run('reuse-' + label, extra, f'reuse-{label}-{round_index}', round_index)
            validate_reuse(report, label == 'candidate', reuse[label][0] if reuse[label] else None)
            reuse[label].append(report)
        before, after = reuse['baseline'][-1], reuse['candidate'][-1]
        require_matching(before, after, ('benchmark', 'zig', 'optimize', 'arch', 'os', 'cpu_target', 'simd_lanes', 'viewport', 'warmups', 'samples'),
                         'reuse baseline/candidate workload')
        before_cases = cases_by_key(before, retained=True)
        after_cases = cases_by_key(after, retained=True)
        for key, candidate_case in after_cases.items():
            require_matching(before_cases[key]['full_rebuild'], candidate_case['full_rebuild'],
                             ('sequence_hash', 'output_hash', 'observed_frames', 'timer_fires', 'keyboard_activations'),
                             f'reuse full-control equivalence {key}')
        invalid_baseline = sum(not case['same_output_and_updates'] for case in before_cases.values())
        print(f'Round {round_index + 1}: reuse candidate valid; {invalid_baseline} baseline retained cases excluded from valid timing comparisons', flush=True)
    environment['completed_utc'] = datetime.now(timezone.utc).isoformat()
    write_json(args.output / 'environment.json', environment)
    summary = {
        'environment': environment,
        'incremental_cases': {name: aggregate_incremental(reports) for name, reports in incremental.items()},
        'reuse': aggregate_reuse(reuse),
    }
    write_json(args.output / 'summary.json', summary)
    print('Saved raw reports, validation evidence and summary to', args.output, flush=True)


if __name__ == '__main__':
    main()
