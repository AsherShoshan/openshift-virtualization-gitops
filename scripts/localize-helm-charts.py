#!/usr/bin/env python3
"""
Scan repository for external Helm charts in kustomization.yaml files,
download them to .helm-charts/, and update references to use local charts.
"""

import os
import sys
import yaml
import subprocess
from pathlib import Path
from urllib.parse import urlparse

# Repository root
REPO_ROOT = Path(__file__).parent.parent.absolute()
HELM_CHARTS_DIR = REPO_ROOT / ".helm-charts"


def find_kustomization_files():
    """Find all kustomization.yaml files in the repository."""
    kustomization_files = []
    for root, dirs, files in os.walk(REPO_ROOT):
        # Skip .git and .helm-charts directories
        dirs[:] = [d for d in dirs if d not in ['.git', '.helm-charts', 'node_modules']]

        for file in files:
            if file in ['kustomization.yaml', 'kustomization.yml']:
                kustomization_files.append(Path(root) / file)

    return kustomization_files


def parse_helm_charts(kustomization_file):
    """Parse helmCharts from a kustomization.yaml file."""
    with open(kustomization_file, 'r') as f:
        data = yaml.safe_load(f)

    if not data or 'helmCharts' not in data:
        return []

    charts = []
    for chart in data.get('helmCharts', []):
        if 'repo' in chart:  # Only process charts with external repos
            charts.append({
                'name': chart.get('name'),
                'repo': chart.get('repo'),
                'version': chart.get('version'),
                'kustomization_file': kustomization_file
            })

    return charts


def download_helm_chart(chart_name, repo_url, version=None):
    """Download a Helm chart from a repository."""
    chart_dir = HELM_CHARTS_DIR / chart_name

    # Create .helm-charts directory if it doesn't exist
    HELM_CHARTS_DIR.mkdir(exist_ok=True)

    # Get the repo index
    print(f"📦 Downloading {chart_name} from {repo_url}")

    try:
        # Fetch index.yaml
        index_url = f"{repo_url.rstrip('/')}/index.yaml"
        result = subprocess.run(
            ['curl', '-sL', index_url],
            capture_output=True,
            text=True,
            check=True
        )

        index = yaml.safe_load(result.stdout)

        # Find the chart entry
        if chart_name not in index.get('entries', {}):
            print(f"  ❌ Chart '{chart_name}' not found in {repo_url}")
            return False

        # Get the appropriate version
        chart_versions = index['entries'][chart_name]
        if version:
            # Find specific version
            chart_info = next((v for v in chart_versions if v.get('version') == version), None)
            if not chart_info:
                print(f"  ❌ Version {version} not found for {chart_name}")
                return False
        else:
            # Get latest version (first in list)
            chart_info = chart_versions[0]

        chart_version = chart_info['version']
        chart_url = chart_info['urls'][0]

        # Make URL absolute if relative
        if not chart_url.startswith('http'):
            chart_url = f"{repo_url.rstrip('/')}/{chart_url.lstrip('/')}"

        print(f"  📥 Version: {chart_version}")
        print(f"  🔗 URL: {chart_url}")

        # Download and extract
        tgz_file = HELM_CHARTS_DIR / f"{chart_name}-{chart_version}.tgz"

        subprocess.run(
            ['curl', '-sL', '-o', str(tgz_file), chart_url],
            check=True
        )

        # Remove existing chart directory if exists
        if chart_dir.exists():
            subprocess.run(['rm', '-rf', str(chart_dir)], check=True)

        # Extract
        subprocess.run(
            ['tar', '-xzf', str(tgz_file), '-C', str(HELM_CHARTS_DIR)],
            check=True
        )

        # Clean up tarball
        tgz_file.unlink()

        print(f"  ✅ Downloaded to .helm-charts/{chart_name}/")
        return True

    except Exception as e:
        print(f"  ❌ Error downloading chart: {e}")
        return False


def update_kustomization_file(kustomization_file, chart_name):
    """Update kustomization.yaml to use local chartHome instead of repo."""
    with open(kustomization_file, 'r') as f:
        content = f.read()

    # Read as YAML to find the chart
    data = yaml.safe_load(content)

    if not data or 'helmCharts' not in data:
        return False

    # Calculate relative path from kustomization.yaml to .helm-charts
    kustomization_dir = kustomization_file.parent
    rel_path = os.path.relpath(HELM_CHARTS_DIR, kustomization_dir)

    # Update the YAML data
    updated = False
    for chart in data['helmCharts']:
        if chart.get('name') == chart_name and 'repo' in chart:
            # Remove repo, add chartHome
            del chart['repo']
            chart['chartHome'] = rel_path
            updated = True

    if updated:
        # Write back with proper formatting
        with open(kustomization_file, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)

        print(f"  ✏️  Updated {kustomization_file.relative_to(REPO_ROOT)}")
        return True

    return False


def main():
    """Main function to localize all Helm charts."""
    print(f"🔍 Scanning repository for external Helm charts...\n")

    # Find all kustomization files
    kustomization_files = find_kustomization_files()
    print(f"Found {len(kustomization_files)} kustomization.yaml files\n")

    # Parse all charts
    all_charts = []
    for kfile in kustomization_files:
        charts = parse_helm_charts(kfile)
        all_charts.extend(charts)

    if not all_charts:
        print("✅ No external Helm charts found (all already localized)")
        return 0

    print(f"📋 Found {len(all_charts)} external Helm chart(s):\n")

    # Download each unique chart
    processed_charts = set()
    for chart in all_charts:
        chart_key = (chart['name'], chart['repo'])

        if chart_key in processed_charts:
            continue

        processed_charts.add(chart_key)

        # Download the chart
        success = download_helm_chart(
            chart['name'],
            chart['repo'],
            chart.get('version')
        )

        if success:
            # Update all kustomization files that use this chart
            for c in all_charts:
                if c['name'] == chart['name'] and c['repo'] == chart['repo']:
                    update_kustomization_file(c['kustomization_file'], chart['name'])

        print()  # Blank line between charts

    print("✅ Done! All Helm charts have been localized to .helm-charts/")
    return 0


if __name__ == '__main__':
    sys.exit(main())
