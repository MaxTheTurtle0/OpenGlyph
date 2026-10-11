#!/usr/bin/env python3
"""Summarize MonitorProcess output without inventing missing observations."""
import argparse
import collections
import csv
import json
import math
import pathlib
import statistics

MIB = 1048576

def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

def percentile(values, proportion):
    values = sorted(v for v in values if finite(v))
    if not values:
        return None
    index = (len(values) - 1) * proportion
    lo, hi = math.floor(index), math.ceil(index)
    return values[lo] + (values[hi] - values[lo]) * (index - lo)

def distribution(values):
    values = [v for v in values if finite(v)]
    if not values:
        return None
    return dict(min=min(values), median=statistics.median(values), p95=percentile(values, .95), max=max(values))

def summarize(directory):
    metadata = json.loads((directory / 'metadata.json').read_text())
    completion_path = directory / 'completion.json'
    completion = json.loads(completion_path.read_text()) if completion_path.exists() else None
    rows, malformed = [], 0
    for line in (directory / 'samples.jsonl').read_text().splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            malformed += 1
    counts = collections.Counter(p.get('identity') for r in rows for p in r.get('processes', []) if p.get('status') == 'ok')
    primary = counts.most_common(1)[0][0] if counts else None
    series = []
    sampler_cpu = []
    sampler_memory = []
    for row in rows:
        gap = row.get('gap_exceeds_threshold', False)
        observer = row.get('sampler', {}).get('metrics', {})
        if not gap and finite(observer.get('interval_cpu_percent')) and finite(observer.get('interval_seconds')):
            sampler_cpu.append((observer['interval_cpu_percent'], observer['interval_seconds']))
        if finite(observer.get('physical_footprint_bytes')):
            sampler_memory.append(observer['physical_footprint_bytes'] / MIB)
        for process in row.get('processes', []):
            if process.get('identity') != primary or process.get('status') != 'ok':
                continue
            metrics = process['metrics']
            interval = metrics.get('interval_seconds')
            valid_cpu = (not gap and metrics.get('interval_status') == 'ok' and finite(interval)
                         and 0 < interval <= metadata['gap_threshold_seconds'] and finite(metrics.get('interval_cpu_percent')))
            series.append(dict(timestamp=row['timestamp'], elapsed_seconds=row['elapsed_seconds'],
                               identity=primary, pid=process['pid'],
                               footprint_mib=metrics['physical_footprint_bytes'] / MIB,
                               resident_mib=metrics['resident_bytes'] / MIB,
                               neural_mib=(process.get('neural', {}).get('neural_footprint_bytes') / MIB
                                           if finite(process.get('neural', {}).get('neural_footprint_bytes')) else None),
                               cpu_percent=metrics.get('interval_cpu_percent') if valid_cpu else None,
                               valid_interval_seconds=interval if valid_cpu else None,
                               threads=process.get('threads'), gap=gap,
                               host_cpu_percent=row.get('host', {}).get('cpu_busy_percent') if not gap else None,
                               system_swap_mib=(row['host']['swap_used_bytes'] / MIB if finite(row.get('host', {}).get('swap_used_bytes')) else None),
                               memory_pressure=row.get('host', {}).get('memory_pressure_level'),
                               thermal_state=row.get('host', {}).get('thermal_state')))
    cpu = [(p['cpu_percent'], p['valid_interval_seconds']) for p in series if finite(p['cpu_percent'])]
    def weighted(values):
        denominator = sum(dt for _, dt in values)
        return sum(v * dt for v, dt in values) / denominator if denominator else None
    summary = dict(status='completed' if completion else 'in_progress', metadata=metadata, completion=completion,
                   samples=len(rows), malformed_lines=malformed, primary_identity=primary,
                   identities_observed=dict(counts), valid_cpu_coverage_seconds=sum(dt for _, dt in cpu),
                   cpu_average_percent=weighted(cpu), cpu_distribution=distribution([v for v, _ in cpu]),
                   footprint_mib=distribution([p['footprint_mib'] for p in series]),
                   resident_mib=distribution([p['resident_mib'] for p in series]),
                   neural_mib=distribution([p['neural_mib'] for p in series]),
                   sampler_cpu_average_percent=weighted(sampler_cpu), sampler_footprint_mib=distribution(sampler_memory),
                   system_swap_mib=distribution([p['system_swap_mib'] for p in series]),
                   thermal_states=dict(collections.Counter(str(p['thermal_state']) for p in series)),
                   memory_pressure_levels=dict(collections.Counter(str(p['memory_pressure']) for p in series)),
                   limitations=metadata.get('limitations', []))
    if series:
        summary['first_footprint_mib'] = series[0]['footprint_mib']
        summary['last_footprint_mib'] = series[-1]['footprint_mib']
        summary['first_to_last_footprint_change_mib'] = series[-1]['footprint_mib'] - series[0]['footprint_mib']
        first_window = [p['footprint_mib'] for p in series if p['elapsed_seconds'] <= series[0]['elapsed_seconds'] + 300]
        last_window = [p['footprint_mib'] for p in series if p['elapsed_seconds'] >= series[-1]['elapsed_seconds'] - 300]
        summary['first_five_minutes_footprint_median_mib'] = statistics.median(first_window)
        summary['last_five_minutes_footprint_median_mib'] = statistics.median(last_window)
    return summary, series

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    args = parser.parse_args()
    summary, series = summarize(args.directory)
    (args.directory / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    if series:
        with (args.directory / 'series.csv').open('w', newline='') as handle:
            writer = csv.DictWriter(handle, fieldnames=list(series[0]))
            writer.writeheader()
            writer.writerows(series)
    print(json.dumps({k: v for k, v in summary.items() if k not in ('metadata', 'completion', 'limitations')}, indent=2, sort_keys=True))

if __name__ == '__main__':
    main()
