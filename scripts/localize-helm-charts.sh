#!/bin/bash
set -eo pipefail

# Error handler
trap 'echo "Error on line $LINENO"' ERR

# Scan repository for external Helm charts in kustomization.yaml files,
# download them to .helm-charts/, and update references to use local charts.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_CHARTS_DIR="${REPO_ROOT}/.helm-charts"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if yq is available for better YAML parsing
if command -v yq &> /dev/null; then
    HAS_YQ=true
else
    HAS_YQ=false
    echo -e "${YELLOW}⚠️  yq not found, using basic parsing (install yq for better reliability)${NC}"
fi

# Create .helm-charts directory if it doesn't exist
mkdir -p "${HELM_CHARTS_DIR}"

find_kustomization_files() {
    find "${REPO_ROOT}" \
        -type f \
        \( -name "kustomization.yaml" -o -name "kustomization.yml" \) \
        ! -path "*/.git/*" \
        ! -path "*/.helm-charts/*" \
        ! -path "*/node_modules/*"
}

parse_helm_charts_with_yq() {
    local kfile="$1"

    # Check if file has helmCharts section
    if ! yq eval '.helmCharts' "$kfile" 2>/dev/null | grep -q "name:"; then
        return 0
    fi

    # Get number of charts
    local chart_count
    chart_count=$(yq eval '.helmCharts | length' "$kfile" 2>/dev/null || echo "0")

    for ((i=0; i<chart_count; i++)); do
        local name repo version
        name=$(yq eval ".helmCharts[$i].name" "$kfile" 2>/dev/null)
        repo=$(yq eval ".helmCharts[$i].repo" "$kfile" 2>/dev/null)
        version=$(yq eval ".helmCharts[$i].version" "$kfile" 2>/dev/null)

        # Only process if repo exists (not null or chartHome)
        if [[ "$repo" != "null" && -n "$repo" ]]; then
            echo "${kfile}|${name}|${repo}|${version}"
        fi
    done
}

parse_helm_charts_basic() {
    local kfile="$1"
    local in_helm_charts=false
    local in_chart=false
    local name="" repo="" version=""

    while IFS= read -r line; do
        # Check if we're in helmCharts section
        if [[ "$line" =~ ^helmCharts: ]]; then
            in_helm_charts=true
            continue
        fi

        # Exit helmCharts if we hit a non-indented line
        if [[ "$in_helm_charts" == true && "$line" =~ ^[a-zA-Z] ]]; then
            break
        fi

        if [[ "$in_helm_charts" == true ]]; then
            # New chart entry (starts with "- name:")
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+) ]]; then
                # Output previous chart if it had a repo
                if [[ -n "$name" && -n "$repo" ]]; then
                    echo "${kfile}|${name}|${repo}|${version}"
                fi
                # Start new chart
                name="${BASH_REMATCH[1]}"
                repo=""
                version=""
                in_chart=true
            elif [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.+) ]]; then
                name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+repo:[[:space:]]*(.+) ]]; then
                repo="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+version:[[:space:]]*(.+) ]]; then
                version="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$kfile"

    # Output last chart if it had a repo
    if [[ -n "$name" && -n "$repo" ]]; then
        echo "${kfile}|${name}|${repo}|${version}"
    fi
}

get_chart_folder_name() {
    local chart_name="$1"
    local chart_version="$2"

    local chart_dir="${HELM_CHARTS_DIR}/${chart_name}"
    local chart_folder_name="${chart_name}"

    # Check if base folder exists
    if [[ -d "$chart_dir" ]]; then
        # Folder exists, use versioned name
        chart_folder_name="${chart_name}-${chart_version}"
        local versioned_dir="${HELM_CHARTS_DIR}/${chart_folder_name}"

        if [[ -d "$versioned_dir" ]]; then
            # Versioned folder also exists
            echo "EXISTS:${chart_folder_name}"
        else
            # Need to create versioned folder
            echo "VERSIONED:${chart_folder_name}"
        fi
    else
        # Base folder doesn't exist, use base name
        echo "NEW:${chart_folder_name}"
    fi
}

download_helm_chart() {
    local chart_name="$1"
    local repo_url="$2"
    local version="$3"

    echo -e "${BLUE}📦 Downloading ${chart_name} from ${repo_url}${NC}" >&2

    # Fetch index.yaml
    local index_url="${repo_url%/}/index.yaml"
    local index_yaml
    index_yaml=$(curl -sL "$index_url" 2>/dev/null) || {
        echo -e "${RED}  ❌ Failed to fetch index from ${repo_url}${NC}" >&2
        return 1
    }

    # Parse index.yaml to find the chart
    local chart_url chart_version

    if [[ "$HAS_YQ" == true ]]; then
        # Use yq for reliable parsing
        if [[ -n "$version" && "$version" != "null" ]]; then
            # Find specific version
            chart_url=$(echo "$index_yaml" | yq eval ".entries.${chart_name}[] | select(.version == \"${version}\") | .urls[0]" -)
            chart_version="$version"
        else
            # Get latest version (first entry)
            chart_url=$(echo "$index_yaml" | yq eval ".entries.${chart_name}[0].urls[0]" -)
            chart_version=$(echo "$index_yaml" | yq eval ".entries.${chart_name}[0].version" -)
        fi
    else
        # Basic parsing with awk/grep
        local in_chart=false
        while IFS= read -r line; do
            if [[ "$line" =~ name:[[:space:]]*${chart_name}$ ]]; then
                in_chart=true
            elif [[ "$in_chart" == true ]]; then
                if [[ "$line" =~ version:[[:space:]]*(.+) ]]; then
                    chart_version="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ -[[:space:]]*http ]]; then
                    chart_url=$(echo "$line" | sed 's/.*- //')
                    break
                fi
            fi
        done <<< "$index_yaml"
    fi

    if [[ -z "$chart_url" || "$chart_url" == "null" ]]; then
        echo -e "${RED}  ❌ Chart '${chart_name}' not found in ${repo_url}${NC}" >&2
        return 1
    fi

    # Make URL absolute if relative
    if [[ ! "$chart_url" =~ ^http ]]; then
        chart_url="${repo_url%/}/${chart_url#/}"
    fi

    echo -e "  📥 Version: ${chart_version}" >&2
    echo -e "  🔗 URL: ${chart_url}" >&2

    # Determine the folder name using helper function
    local folder_status
    folder_status=$(get_chart_folder_name "$chart_name" "$chart_version")

    local status_type="${folder_status%%:*}"
    local chart_folder_name="${folder_status#*:}"
    local chart_dir="${HELM_CHARTS_DIR}/${chart_folder_name}"

    case "$status_type" in
        EXISTS)
            echo -e "${YELLOW}  ⚠️  Chart ${chart_folder_name} already exists, skipping download${NC}" >&2
            echo "$chart_folder_name"
            return 0
            ;;
        VERSIONED)
            echo -e "${YELLOW}  ⚠️  Base folder exists, creating versioned folder: ${chart_folder_name}${NC}" >&2
            ;;
        NEW)
            # New chart, no message needed
            ;;
    esac

    # Download chart
    local tgz_file="${HELM_CHARTS_DIR}/${chart_name}-${chart_version}.tgz"
    curl -sL -o "$tgz_file" "$chart_url" || {
        echo -e "${RED}  ❌ Failed to download chart${NC}" >&2
        return 1
    }

    # Extract to temporary directory first
    local temp_extract_dir="${HELM_CHARTS_DIR}/tmp-${chart_name}"
    mkdir -p "$temp_extract_dir"

    tar -xzf "$tgz_file" -C "$temp_extract_dir" || {
        echo -e "${RED}  ❌ Failed to extract chart${NC}" >&2
        rm -f "$tgz_file"
        rm -rf "$temp_extract_dir"
        return 1
    }

    # Move the extracted chart to the final location with correct name
    # Charts usually extract to a folder named after the chart
    if [[ -d "${temp_extract_dir}/${chart_name}" ]]; then
        mv "${temp_extract_dir}/${chart_name}" "$chart_dir"
    else
        # If extraction didn't create expected folder, move the whole temp dir
        mv "$temp_extract_dir" "$chart_dir"
    fi

    # Clean up
    rm -rf "$temp_extract_dir"
    rm -f "$tgz_file"

    echo -e "${GREEN}  ✅ Downloaded to .helm-charts/${chart_folder_name}/${NC}" >&2

    # Return the folder name for use in kustomization updates
    echo "$chart_folder_name"
    return 0
}

update_kustomization_file() {
    local kfile="$1"
    local chart_name="$2"
    local chart_folder_name="$3"  # The actual folder name (may be versioned)

    # Calculate relative path from kustomization.yaml to .helm-charts
    local kfile_dir
    kfile_dir="$(dirname "$kfile")"
    local rel_path
    rel_path="$(realpath --relative-to="$kfile_dir" "$HELM_CHARTS_DIR")"

    if [[ "$HAS_YQ" == true ]]; then
        # Use yq to update properly
        # Update the name field if it's a versioned folder
        if [[ "$chart_name" != "$chart_folder_name" ]]; then
            yq eval -i "(.helmCharts[] | select(.name == \"${chart_name}\" and .repo)).name = \"${chart_folder_name}\"" "$kfile"
        fi
        yq eval -i "(.helmCharts[] | select(.name == \"${chart_folder_name}\" and .repo) | .chartHome) = \"${rel_path}\"" "$kfile"
        yq eval -i "del(.helmCharts[] | select(.name == \"${chart_folder_name}\") | .repo)" "$kfile"
    else
        # Basic sed replacement (less reliable but works for simple cases)
        # This is a simplified approach - for complex YAML, yq is recommended
        local temp_file="${kfile}.tmp"
        local in_target_chart=false
        local name_updated=false

        while IFS= read -r line; do
            # Detect if we're in the target chart
            if [[ "$line" =~ name:[[:space:]]*${chart_name}$ ]]; then
                in_target_chart=true
                # Update name if using versioned folder
                if [[ "$chart_name" != "$chart_folder_name" && "$name_updated" == false ]]; then
                    local indent="${line%%[![:space:]]*}"
                    echo "${indent}name: ${chart_folder_name}"
                    name_updated=true
                else
                    echo "$line"
                fi
            elif [[ "$in_target_chart" == true && "$line" =~ repo:[[:space:]]* ]]; then
                # Replace repo with chartHome
                local indent="${line%%[![:space:]]*}"
                echo "${indent}chartHome: ${rel_path}"
                in_target_chart=false
            else
                echo "$line"
                # Reset if we hit another chart or section
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                    in_target_chart=false
                fi
            fi
        done < "$kfile" > "$temp_file"

        mv "$temp_file" "$kfile"
    fi

    local rel_kfile
    rel_kfile="$(realpath --relative-to="$REPO_ROOT" "$kfile")"
    echo -e "${GREEN}  ✏️  Updated ${rel_kfile}${NC}" >&2
}

main() {
    echo -e "${BLUE}🔍 Scanning repository for external Helm charts...${NC}\n"

    # Find all kustomization files
    local kfiles
    mapfile -t kfiles < <(find_kustomization_files)
    echo -e "Found ${#kfiles[@]} kustomization.yaml files\n"

    # Parse all charts
    declare -A charts # chart_name|repo -> kfiles
    local total_charts=0

    echo -e "Parsing kustomization files..." >&2

    for kfile in "${kfiles[@]}"; do
        local chart_entries
        if [[ "$HAS_YQ" == true ]]; then
            mapfile -t chart_entries < <(parse_helm_charts_with_yq "$kfile")
        else
            mapfile -t chart_entries < <(parse_helm_charts_basic "$kfile")
        fi

        for entry in "${chart_entries[@]}"; do
            if [[ -n "$entry" ]]; then
                IFS='|' read -r kfile_path name repo version <<< "$entry"
                local key="${name}|${repo}"
                charts["$key"]="${charts[$key]:-}${kfile_path}|${version};"
                total_charts=$((total_charts + 1))
            fi
        done
    done

    echo -e "Total charts found: $total_charts" >&2

    if [[ $total_charts -eq 0 ]]; then
        echo -e "${GREEN}✅ No external Helm charts found (all already localized)${NC}"
        return 0
    fi

    echo -e "📋 Found ${total_charts} external Helm chart(s):\n"

    # Download and update each unique chart
    for key in "${!charts[@]}"; do
        IFS='|' read -r chart_name repo_url <<< "$key"
        local entries="${charts[$key]}"

        # Get version from first entry
        local version
        version=$(echo "$entries" | cut -d';' -f1 | cut -d'|' -f2)

        # Download the chart and capture the folder name
        local download_output
        download_output=$(download_helm_chart "$chart_name" "$repo_url" "$version")
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            # Extract the folder name from the last line of output
            local chart_folder_name
            chart_folder_name=$(echo "$download_output" | tail -1)

            # If empty or looks like a message, use original name
            if [[ -z "$chart_folder_name" || "$chart_folder_name" =~ ^[[:space:]]*$ ]]; then
                chart_folder_name="$chart_name"
            fi

            # Update all kustomization files that use this chart
            while IFS=';' read -r entry; do
                if [[ -n "$entry" ]]; then
                    local kfile_path
                    kfile_path=$(echo "$entry" | cut -d'|' -f1)
                    update_kustomization_file "$kfile_path" "$chart_name" "$chart_folder_name"
                fi
            done <<< "${entries}"
        fi

        echo ""
    done

    echo -e "${GREEN}✅ Done! All Helm charts have been localized to .helm-charts/${NC}"
    return 0
}

main "$@"
