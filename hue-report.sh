#!/bin/bash
#
# Cross-Platform Hue Asset Reporter
#
# Description:
# This script connects to Philips Hue Bridges, fetches data about all assets
# using an optimized API call, supplemented by individual calls for scene details,
# and generates a human-readable HTML report as well as a raw JSON data dump.
# For multi-bridge setups, it fetches data in parallel, using a number of
# jobs appropriate for the system's CPU cores.
#
# Author: Lachezar Vladikov
# Version: 1.1.9
#
# ==============================================================================
# REQUIREMENTS
# ==============================================================================
#
# 1. A Bash-compatible shell:
#    - macOS: Included by default (Terminal).
#    - Linux: Included by default.
#    - Windows: Two excellent options are available:
#      a) Windows Subsystem for Linux (WSL): Provides a full Linux environment
#         and is the recommended method. Install it from the Microsoft Store.
#      b) Git for Windows: Provides "Git Bash", a lightweight Bash environment.
#         Download from https://git-scm.com/download/win
#
# 2. jq - A command-line JSON processor:
#    This script relies heavily on `jq` to parse the complex JSON data returned
#    by the Hue Bridge API. It's a lightweight and powerful tool for slicing,
#    filtering, and transforming structured data.
#
#    --- Installation Instructions ---
#
#    - macOS (using Homebrew):
#      brew install jq
#
#    - Linux (Debian/Ubuntu/WSL):
#      sudo apt-get update && sudo apt-get install jq
#
#    - Linux (Fedora/CentOS/RHEL):
#      sudo dnf install jq
#
#    - Windows (using Chocolatey package manager in PowerShell):
#      choco install jq
#
#    - Windows (using winget in PowerShell):
#      winget install jqlang.jq
#
#    - Windows (Manual):
#      Download the executable from https://jqlang.github.io/jq/download/ and
#      place it in a directory that is in your system's PATH.
#
# ==============================================================================
# CONFIGURATION SETUP (hue_bridges_conf.json)
# ==============================================================================
#
# Before running the script, you must create a configuration file named
# `hue_bridges_conf.json` in the same directory as this script.
#
# --- File Format ---
# The file must be a valid JSON array of bridge objects, like this:
#
# [
#    {
#      "name": "My Living Room Bridge",
#      "ip": "192.168.1.123",
#      "user": "YOUR_GENERATED_API_USER_HERE"
#    },
#    {
#      "name": "Upstairs Bridge",
#      "ip": "192.168.1.124",
#      "user": "ANOTHER_GENERATED_API_USER"
#    }
# ]
#
# --- How to Find Your Bridge IP and Generate a User ---
#
# 1. Find your Bridge's IP Address:
#    - Open the official Philips Hue app on your phone.
#    - Go to: Settings -> My Hue System -> [Select your Bridge]
#    - The IP address will be listed under "Network settings".
#
# 2. Generate an API User (Username):
#    This is a one-time step for each bridge. You will need a terminal
#    (Terminal on macOS/Linux, WSL or Git Bash on Windows). The `curl`
#    command is available by default in all these environments.
#
#    a) Run the following `curl` command, replacing `<BRIDGE_IP_ADDRESS>`
#       with the IP you found in step 1.
#
#       curl -X POST http://<BRIDGE_IP_ADDRESS>/api -H "Content-Type: application/json" -d '{"devicetype":"hue_reporter_script#computer"}'
#
#    b) The command will seem to hang and will return a response like:
#       [{"error":{"type":101,"address":"","description":"link button not pressed"}}]
#
#    c) Within 30 seconds of seeing that response, physically press the round
#       link button on the top of your Hue Bridge.
#
#    d) Run the exact same `curl` command from step 2a again. This time, you
#       will get a success response containing your username:
#
#       [{"success":{"username":"THIS_IS_YOUR_USERNAME_COPY_IT"}}]
#
# 3. Update the JSON file:
#    - Copy the generated username from the success response.
#    - Paste it into the "user" field in your `hue_bridges_conf.json` file.
#    - Give your bridge a descriptive "name" and add its "ip".
#    - Repeat for any other bridges you have.
#
# ==============================================================================
# MANAGING DEVICE SERIAL NUMBERS (hue_serials_mapping.json)
# ==============================================================================
#
# The Hue API does not provide device serial numbers for security reasons. To
# make the report more complete, you can provide this information yourself by
# running option "2. Create/Update Light Serial Number Mapping File".
#
# --- How It Works ---
# 1. First Run (Creating the Template):
#    The first time you run this option, the script will create a file named
#    `hue_serials_mapping.json`. This file acts as a template, dynamically
#    populated with every light discovered from your bridge(s). Each entry
#    provides detailed context to help you identify the physical device:
#
#    "<unique_device_id>": {
#      "name": "<device_name>",
#      "serialNumber": "",
#      "bridgeName": "<bridge_name>",
#      "type": "<device_type>",
#      "groupNames": [
#        "<group_1_device_belongs_to>"
#      ]
#    }
#
# 2. Add Your Serial Numbers:
#    You can then edit this JSON file and fill in the empty `serialNumber`
#    field for each device.
#
# 3. Subsequent Runs:
#    On subsequent runs, the script will refresh the list of lights from your
#    bridges but will preserve any serial numbers you have already added to the
#    `hue_serials_mapping.json` file. This allows you to progressively add
#    information as you find it.
#
# 4. Missing Serial Number Reports:
#    Both the console output and the final HTML report will include a summary
#    of any lights that are still missing a serial number, making it easy to
#    track which ones still need to be updated.
#
# --- OPTIONAL: Pre-populating with a Plain Text File ---
#
# To speed up the process, you can create a plain text file named
# `hue_serials_mapping-plain-text-info.txt`. The script will use this file
# to automatically fill in serial numbers when you run option 2.
#
#    - File Format: Add one line per device using the pattern:
#      SN: <SERIAL_NUMBER> -> <DEVICE_NAME>
#
#    - Comments: Lines starting with a hash symbol (#) are ignored.
#
#    - Example `hue_serials_mapping-plain-text-info.txt` File:
#
#      # My Hue Lights Inventory
#
#      # Living Room
#      SN: H12345678 -> Living Room Ceiling 1
#      SN: H87654321 -> Living Room Lamp
#      # SN: H00000000 -> Old lamp (commented out for now)
#
#      # Kitchen
#      - SN: K99887766 -> Kitchen Under Cabinet
#
# ==============================================================================

# Determine the absolute path of the directory where the script is located.
# This method is robust and works on macOS, Linux, and in Git Bash for Windows.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONFIG_FILE="$SCRIPT_DIR/hue_bridges_conf.json"

# Global variable to hold the loaded bridge configuration
BRIDGES_JSON=""

# Function to get the number of available CPU cores in a cross-platform way.
get_core_count() {
    case "$(uname -s)" in
        Linux*)   nproc ;;
        Darwin*)  sysctl -n hw.ncpu ;;
        CYGWIN*|MINGW*|MSYS*) echo "$NUMBER_OF_PROCESSORS" ;;
        *)        echo "2" ;; # Fallback to a safe default of 2 cores
    esac
}

# Function to load configuration from external JSON file
load_config() {
    echo "Loading configuration from '$CONFIG_FILE'..."
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file '$CONFIG_FILE' not found."
        echo "Please ensure it is in the same directory as this script and add your bridge details."
        exit 1
    fi
    
    BRIDGES_JSON=$(cat "$CONFIG_FILE")
    
    # Validate the JSON
    if ! echo "$BRIDGES_JSON" | jq empty &>/dev/null; then
        echo "Error: Configuration file '$CONFIG_FILE' contains invalid JSON."
        exit 1
    fi

    echo "Configuration loaded."
}

# Function to check for required command-line tools
check_dependencies() {
    echo "Checking for required tools..."
    if ! command -v jq &> /dev/null; then
        echo "Error: 'jq' is not installed or not in your system's PATH."
        echo "Please see the installation instructions in the script's header."
        exit 1
    fi
    echo "All tools found."
    echo
}

# Function to allow the user to select a bridge for reporting
select_bridge() {
    echo "Please select a Hue Bridge to report on:"
    
    local bridge_count
    bridge_count=$(echo "$BRIDGES_JSON" | jq 'length')

    if [ "$bridge_count" -eq 0 ]; then
        echo "No configured bridges found in '$CONFIG_FILE'."
        echo "Please edit the configuration file and add your bridge details."
        exit 1
    fi
    
    # Dynamically display bridges from JSON
    for i in $(seq 0 $((bridge_count - 1))); do
        local name
        name=$(echo "$BRIDGES_JSON" | jq -r ".[$i].name")
        local ip
        ip=$(echo "$BRIDGES_JSON" | jq -r ".[$i].ip")
        echo "  $((i+1)). $name ($ip)"
    done

    # Add the "All Bridges" option
    local all_option_num=$((bridge_count + 1))
    echo "  $all_option_num. All Configured Bridges"
    
    local choice
    read -p "Enter number (1-$all_option_num) [default: $all_option_num]: " choice

    # Default to "All" if the user just presses Enter
    if [[ -z "$choice" ]]; then
        choice=$all_option_num
    fi

    if [[ "$choice" == "$all_option_num" ]]; then
        SELECTED_BRIDGE_NAME="All Configured Bridges"
        SELECTED_BRIDGE_IP="ALL" # Special flag for the fetch function
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$bridge_count" ]; then
        local selected_bridge_obj
        selected_bridge_obj=$(echo "$BRIDGES_JSON" | jq ".[$((choice-1))]")
        
        # Set global variables for the selected bridge
        SELECTED_BRIDGE_IP=$(echo "$selected_bridge_obj" | jq -r ".ip")
        SELECTED_BRIDGE_USER=$(echo "$selected_bridge_obj" | jq -r ".user")
        SELECTED_BRIDGE_NAME=$(echo "$selected_bridge_obj" | jq -r ".name")
    else
        echo "Invalid selection. Exiting."
        exit 1
    fi
}

# Function to fetch all data from the Hue API. It uses a single call per bridge
# for most assets, then fetches detailed scene data individually for accuracy.
fetch_data() {
    echo

    local bridges_to_fetch_json
    if [[ "$SELECTED_BRIDGE_IP" == "ALL" ]]; then
        echo "Fetching data from ALL configured bridges in parallel..."
        bridges_to_fetch_json="$BRIDGES_JSON"
    else
        echo "Fetching data from '$SELECTED_BRIDGE_NAME'..."
        bridges_to_fetch_json=$(echo "$BRIDGES_JSON" | jq --arg name "$SELECTED_BRIDGE_NAME" '[.[] | select(.name == $name)]')
    fi
    
    local core_count=$(get_core_count)
    echo "Using up to $core_count parallel jobs for fetching..."

    local pids=()
    local tmp_files=()
    
    # Launch curl jobs in the background, managed by the number of CPU cores
    # Note: wait -n requires Bash 4.3+, which is standard on modern systems.
    local job_count=0
    while read -r bridge_obj; do
        if [[ $job_count -ge $core_count ]]; then
            wait -n
            ((job_count--))
        fi

        local current_name=$(echo "$bridge_obj" | jq -r '.name')
        local current_ip=$(echo "$bridge_obj" | jq -r '.ip')
        local current_user=$(echo "$bridge_obj" | jq -r '.user')
        local tmp_file=$(mktemp)
        tmp_files+=("$tmp_file")
        
        (
            echo "--> Contacting '${current_name}'..."
            local full_url="http://${current_ip}/api/${current_user}"
            local response
            response=$(curl --connect-timeout 5 -s "$full_url")
            
            # Add bridge IP and user to the response for later processing
            if [[ -n "$response" && "$response" != *"unauthorized user"* ]]; then
                echo "$response" | jq --arg ip "$current_ip" --arg user "$current_user" '. + {bridge_ip: $ip, bridge_user: $user}' > "$tmp_file"
            else
                echo "{\"error\": \"Failed to fetch data from ${current_name}\", \"bridge_name\": \"${current_name}\"}" > "$tmp_file"
            fi
        ) &
        pids+=($!)
        ((job_count++))
    done < <(echo "$bridges_to_fetch_json" | jq -c '.[]')

    # Wait for all remaining background jobs to complete
    wait "${pids[@]}"
    echo
    echo "All bridges have responded. Processing data..."

    local combined_response="[]"
    # Process the results from the temporary files
    for tmp_file in "${tmp_files[@]}"; do
        local response_json
        response_json=$(cat "$tmp_file")
        
        if echo "$response_json" | jq -e '.error' >/dev/null; then
            local bridge_name
            bridge_name=$(echo "$response_json" | jq -r '.bridge_name')
            echo "     Warning: Could not fetch data from '${bridge_name}'. Skipping."
            continue
        fi

        # --- NEW: Fetch detailed scene data ---
        local bridge_ip=$(echo "$response_json" | jq -r '.bridge_ip')
        local bridge_user=$(echo "$response_json" | jq -r '.bridge_user')
        local scenes_json=$(echo "$response_json" | jq '.scenes')
        local scene_ids=$(echo "$scenes_json" | jq -r 'keys[]')
        
        if [[ -n "$scene_ids" ]]; then
            echo "     Fetching details for scenes on '$(echo "$response_json" | jq -r '.config.name')'..."
            for scene_id in $scene_ids; do
                local scene_detail_url="http://${bridge_ip}/api/${bridge_user}/scenes/${scene_id}"
                local scene_detail_response=$(curl --connect-timeout 5 -s "$scene_detail_url")
                
                # Merge the detailed lightstates back into the main scenes object
                if echo "$scene_detail_response" | jq -e '.lightstates' &>/dev/null; then
                    local lightstates=$(echo "$scene_detail_response" | jq '.lightstates')
                    scenes_json=$(echo "$scenes_json" | jq --arg id "$scene_id" --argjson states "$lightstates" '.[$id].lightstates = $states')
                fi
            done
            # Replace the original scenes object with the updated one
            response_json=$(echo "$response_json" | jq --argjson new_scenes "$scenes_json" '.scenes = $new_scenes')
        fi
        # --- END NEW SECTION ---

        # Re-structure the full dump into the format the script expects
        local bridge_data
        bridge_data=$(echo "$response_json" | jq '{
            bridge_name: .config.name,
            bridge_ip: .bridge_ip,
            bridge_user: .bridge_user,
            config: .config,
            groups: .groups,
            scenes: .scenes,
            sensors: .sensors,
            schedules: .schedules,
            rules: .rules,
            resourcelinks: .resourcelinks,
            lights: .lights
        }')
        
        # Safely merge the new bridge data via standard input to avoid "Argument list too long"
        combined_response=$(printf '%s\n%s' "$combined_response" "$bridge_data" | jq -s '.[0] + [.[1]]')

        # Extract bridge name for logging
        bridge_name=$(jq -r .bridge_name <<< "$bridge_data")
        echo "     Successfully processed and merged data for '$bridge_name'."
        rm "$tmp_file" # Clean up
    done

    API_RESPONSE=$combined_response
    if [[ "$API_RESPONSE" == "[]" || "$API_RESPONSE" == "null" ]]; then
        echo "Error: Could not fetch data from ANY configured bridges. No report can be generated."
        exit 1
    fi
    echo "Successfully received all data."
}


# Optimized function to generate the serial number mapping file.
# Fetches from all bridges in parallel.
generate_serials_file() {
    echo
    echo "Fetching light and group data from ALL configured bridges in parallel..."
    local serials_file="$SCRIPT_DIR/hue_serials_mapping.json"
    local plain_text_file="$SCRIPT_DIR/hue_serials_mapping-plain-text-info.txt"
    
    local core_count=$(get_core_count)
    echo "Using up to $core_count parallel jobs for fetching..."
    
    # --- Parallel Fetching ---
    local pids=()
    local tmp_files=()
    local job_count=0
    while read -r bridge_obj; do
        if [[ $job_count -ge $core_count ]]; then
            wait -n
            ((job_count--))
        fi
        local current_name=$(echo "$bridge_obj" | jq -r '.name')
        local current_ip=$(echo "$bridge_obj" | jq -r '.ip')
        local current_user=$(echo "$bridge_obj" | jq -r '.user')
        local tmp_file=$(mktemp)
        tmp_files+=("$tmp_file")
        (
            echo "--> Contacting '${current_name}'..."
            local full_url="http://${current_ip}/api/${current_user}"
            local response=$(curl --connect-timeout 5 -s "$full_url")
            if [[ -n "$response" && "$response" != *"unauthorized user"* ]]; then
                # We only need lights, groups, and the bridge name from config
                echo "$response" | jq '{lights: .lights, groups: .groups, bridgeName: .config.name}' > "$tmp_file"
            else
                echo "{\"error\": \"Failed to fetch from ${current_name}\", \"bridgeName\": \"${current_name}\"}" > "$tmp_file"
            fi
        ) &
        pids+=($!)
        ((job_count++))
    done < <(echo "$BRIDGES_JSON" | jq -c '.[]')
    
    wait "${pids[@]}"
    echo
    echo "All bridges responded. Processing serials..."

    # --- Processing Results ---
    local combined_array="[]"
    for tmp_file in "${tmp_files[@]}"; do
        local bridge_data=$(cat "$tmp_file")
        rm "$tmp_file" # Clean up early

        if echo "$bridge_data" | jq -e '.error' >/dev/null; then
            local bridge_name=$(echo "$bridge_data" | jq -r '.bridgeName')
            echo "     Warning: Could not fetch lights from '${bridge_name}'. Skipping."
            continue
        fi

        local light_to_groups_map
        light_to_groups_map=$(echo "$bridge_data" | jq '.groups | to_entries | reduce .[] as $group ({}; reduce $group.value.lights[] as $light_id (.; .[$light_id] += [$group.value.name]))')

        local partial_array
        partial_array=$(echo "$bridge_data" | jq --argjson group_map "$light_to_groups_map" '
            .lights | to_entries | map({
                uniqueid: .value.uniqueid,
                name: .value.name,
                type: .value.type,
                bridgeName: .bridgeName,
                groupNames: ($group_map[.key] | sort // [])
            })
        ')
        
        combined_array=$(echo "$combined_array" | jq --argjson data "$partial_array" '. + $data')
    done
    
    if [[ "$combined_array" == "[]" || "$combined_array" == "null" ]]; then
        echo "Error: Could not fetch data from any configured bridges. No file generated."
        return
    fi

    # --- File Generation ---
    local existing_serials_json="{}"
    if [ -f "$serials_file" ]; then
        echo "Reading existing serial numbers from '$serials_file'..."
        existing_serials_json=$(cat "$serials_file")
    fi
    
    local text_serials_json="{}"
    if [ -f "$plain_text_file" ]; then
        echo "Parsing plain text serial number file..."
        
        api_names=()
        while IFS= read -r line; do
            api_names+=("$line")
        done < <(echo "$combined_array" | jq -r '.[].name' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

        local json_payload=""
        while IFS= read -r line; do
            # Ignore comment lines (starting with #) and empty lines
            if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
                continue
            fi
            
            # Match the pattern "SN: ... -> ..." anywhere on the line
            if [[ "$line" =~ SN:[[:space:]]*(.+)[[:space:]]+'->'[[:space:]]+(.*)$ ]]; then
                local serial="${BASH_REMATCH[1]}"
                local full_name_part="${BASH_REMATCH[2]}"
                
                for api_name in "${api_names[@]}"; do
                    api_name_safe_for_regex=$(printf '%s\n' "$api_name" | sed 's/[][\.^*$/]/\\&/g')
                    if [[ "$full_name_part" =~ ^${api_name_safe_for_regex}(\ |$) ]]; then
                        serial=$(echo "$serial" | xargs)
                        json_payload+=$(jq -n --arg k "$api_name" --arg v "$serial" '{($k): $v}')
                        break
                    fi
                done
            fi
        done < "$plain_text_file"

        text_serials_json=$(echo "$json_payload" | jq -s 'add // {}')
    fi

    local intermediate_array
    intermediate_array=$(echo "$combined_array" | jq --argjson existing_serials "$existing_serials_json" --argjson text_serials "$text_serials_json" '
        map(
            . as $item |
            . + {
                existing_serial: ($existing_serials[$item.uniqueid].serialNumber // ""),
                text_serial: ($text_serials[$item.name] // "")
            }
        )
    ')

    echo "Checking for new serial numbers from plain text file..."
    while read -r light_obj; do
        local existing_serial=$(echo "$light_obj" | jq -r '.existing_serial')
        local text_serial=$(echo "$light_obj" | jq -r '.text_serial')
        local light_name=$(echo "$light_obj" | jq -r '.name')
        
        if [[ -z "$existing_serial" && -n "$text_serial" ]]; then
            echo "   -> Match for '$light_name' found. Populating serial: $text_serial"
        fi
    done < <(echo "$intermediate_array" | jq -c '.[]')

    local final_json
    final_json=$(echo "$intermediate_array" | jq '
        sort_by({bridgeName, groupNames: (.groupNames | tostring), name}) | reduce .[] as $item ({}; . + {
            ($item.uniqueid): {
                name: $item.name,
                serialNumber: (if $item.existing_serial != "" then $item.existing_serial else $item.text_serial end),
                bridgeName: $item.bridgeName,
                type: $item.type,
                groupNames: $item.groupNames
            }
        })
    ')

    echo "$final_json" | jq '.' > "$serials_file"
    echo
    echo "✅ Successfully created/updated '$serials_file'."
    echo "Please open the file and manually add the serial numbers for each light."
    
    echo
    local summary_data=$(echo "$combined_array" | jq 'group_by(.bridgeName) | map({bridge: .[0].bridgeName, count: length})')
    local total_count
    total_count=$(echo "$combined_array" | jq 'length')

    echo "--- Light Count Summary ---"
    echo "$summary_data" | jq -r '.[] | "  - \(.bridge): \(.count) lights found."'
    echo "---------------------------"
    echo "  Total: $total_count lights across all bridges."
    
    print_console_summaries "$combined_array" "$final_json"
}

# Function to print console summaries for unreachable lights and missing serials
print_console_summaries() {
    local all_lights_json="$1"
    local serials_json_content="$2"

    # 1. Missing Serial Numbers Console Report
    local missing_serials_console
    missing_serials_console=$(echo "$all_lights_json" | jq --argjson serials "$serials_json_content" -r '
        map(select(($serials[.uniqueid].serialNumber // "") == ""))
        | group_by(.bridgeName)
        | if length > 0 then
            "--- Lights Missing Serial Numbers ---" +
            (map(
                "\n  \u001b[1m" + .[0].bridgeName + "\u001b[0m" + # Bold bridge name
                (map("\n    - " + .name) | join(""))
            ) | join(""))
        else
            ""
        end
    ')

    # 2. Unreachable Lights Console Report
    local unreachable_lights_console
    unreachable_lights_console=$(echo "$all_lights_json" | jq -r '
        map(select(.state.reachable == false))
        | group_by(.bridgeName)
        | if length > 0 then
            "--- Unreachable Lights ---" +
            (map(
                "\n  \u001b[1m" + .[0].bridgeName + "\u001b[0m" + # Bold bridge name
                (map("\n    - " + .name) | join(""))
            ) | join(""))
        else
            ""
        end
    ')
    
    if [[ -n "$missing_serials_console" ]]; then
        echo
        echo -e "$missing_serials_console"
    fi
    if [[ -n "$unreachable_lights_console" ]]; then
        echo
        echo -e "$unreachable_lights_console"
    fi
}

# Cross-platform function to open a file with the default application.
open_command() {
    case "$(uname -s)" in
        Linux*)   xdg-open "$1" &>/dev/null ;;
        Darwin*)  open "$1" ;;
        CYGWIN*|MINGW*|MSYS*) start "" "$1" ;; # For Git Bash on Windows
        *)        echo "Could not detect OS to automatically open the file."
                  echo "Please open '$1' manually." ;;
    esac
}

# Function to process the data and generate a styled HTML report
generate_report() {
    echo "Generating report..."
    local report_date=$(date "+%A, %d %B %Y at %I:%M %p")
    local timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
    local safe_bridge_name
    safe_bridge_name=$(echo "$SELECTED_BRIDGE_NAME" | tr ' ' '.')
    local output_html="Hue.Report-${safe_bridge_name}-${timestamp}.html"
    local output_json="${output_html%.html}.json"
    local serials_file="$SCRIPT_DIR/hue_serials_mapping.json"
    local serials_json_content="{}"
    local report_generation_successful=true

    if [ -f "$serials_file" ]; then
        serials_json_content=$(cat "$serials_file")
        echo "Loaded serial number mappings from '$serials_file'."
    else
        echo "Info: Optional serials mapping file not found. Serial numbers will not be displayed."
    fi

    if ! echo "$API_RESPONSE" | jq empty &>/dev/null; then
        echo "Error: The API response was not valid JSON."
        echo "Please check your connection and the bridge's status."
        exit 1
    fi

    local sorted_bridges_json
    sorted_bridges_json=$(echo "$API_RESPONSE" | jq 'sort_by(.bridge_name)')
    if [[ $? -ne 0 ]]; then echo "Error: jq failed while sorting bridge data." >&2; report_generation_successful=false; fi

    local all_lights_json
    if [[ "$report_generation_successful" == "true" ]]; then
        all_lights_json=$(echo "$sorted_bridges_json" | jq '[.[] as $bridge | $bridge.lights | to_entries | .[] | .value + {light_id: .key, bridgeName: $bridge.bridge_name}] | sort_by(.bridgeName, .name)')
        if [[ $? -ne 0 ]]; then echo "Error: jq failed while creating flat list of all lights." >&2; report_generation_successful=false; fi
    fi

    # Create Report Header and CSS styles
    if [[ "$report_generation_successful" == "true" ]]; then
        cat << EOF > "$output_html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Hue Assets Report</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.5; color: #333; }
        .container { width: 95%; margin: auto; }
        h1 { color: #1a1a1a; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        .report-meta { color: #666; font-size: 0.9em; margin-bottom: 25px; }
        .bridge-info, .light-entry, .group-info, .sensor-info, .schedule-info, .rule-info, .resourcelink-info {
            border: 1px solid #ddd; border-radius: 8px; padding: 15px; margin-bottom: 20px; background-color: #f9f9f9;
        }
        .bridge-info { background-color: #eef; border-color: #aac; }
        .bridge-info ~ .bridge-info {
            border-width: thick;
            margin-top: 100px;
        }
        .group-info { background-color: #eff; border-color: #ace; }
        .sensor-info { background-color: #fefee8; border-color: #dbc687; }
        .schedule-info { background-color: #e8f5e9; border-color: #a5d6a7; }
        .rule-info { background-color: #f3e5f5; border-color: #ce93d8; }
        .resourcelink-info { background-color: #e3f2fd; border-color: #90caf9; }
        .light-name, .bridge-name, .group-name, .sensor-name, .schedule-name, .rule-name, .resourcelink-name {
            font-size: 1.5em; font-weight: bold; margin-top: 0; margin-bottom: 10px; color: #005a9e;
        }
        .detail-row { margin: 0; padding: 3px 0; }
        .label { font-weight: bold; color: #444; }
        .section-header { margin-top: 12px; padding-top: 8px; border-top: 1px solid #e0e0e0; color: #333; font-size: 1.3em; font-weight: bold; }
        .toc { border: 1px solid #ddd; border-radius: 8px; padding: 10px 20px; margin-bottom: 30px; background-color: #fdfdfd; }
        .toc-title { margin-top: 0; border-bottom: 1px solid #eee; padding-bottom: 5px; }
        .summary-title { margin-top: 30px; border-bottom: 1px solid #ccc; padding-bottom: 5px; }
        .bridge-group-title { margin-top: 15px; margin-bottom: 5px; font-size: 1.1em; color: #555; font-weight: bold; }
        ul { margin-top: 0; padding-left: 20px; list-style-type: circle; }
        a { color: #3a3a5e; text-decoration: underline; }
        a:hover { text-decoration: none; }
        table { width: 100%; margin-top: 10px; border-collapse: collapse; }
        th, td { border: 1px solid #ccc; padding: 8px; text-align: left; font-size: 0.9em; }
        th { background-color: #eaf2f8; }
        .infographic { position: relative; margin-top: 5px; margin-bottom: 20px; }
        .marker { position: absolute; top: -2px; width: 2px; height: 24px; background-color: black; border: 1px solid white; transform: translateX(-50%); z-index: 10; }
        .color-block-container { display: inline-block; vertical-align: middle; width: 60px; height: 20px; border: 1px solid #aaa; border-radius: 4px; margin-left: 0; background-color: #f0f0f0; }
        .color-block { width: 100%; height: 100%; border-radius: 3px; }
        .unreachable { color: #d9534f; font-weight: bold; }
        .reachable { color: #5cb85c; font-weight: bold; }
        .on { font-weight: bold; }
        .off { color: #777; }
        .scene-state-container { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .scene-status { padding: 2px 6px; border-radius: 4px; font-size: 0.8em; font-weight: bold; color: white; }
        .status-on { background-color: #5cb85c; }
        .status-off { background-color: #777; }
        .mini-infographic-wrap { display: flex; align-items: center; gap: 5px; font-size: 0.9em; }
        .mini-infographic { position: relative; width: 80px; height: 12px; border: 1px solid #ccc; border-radius: 3px; }
        .mini-marker { position: absolute; top: -2px; width: 2px; height: 16px; background-color: black; border: 1px solid white; transform: translateX(-50%); }
        .bri-gradient { background: linear-gradient(to right, #ddd, #333); }
        .ct-gradient { background: linear-gradient(to right, #ff9a2e, #fff, #cce6ff); }
        .scene-title { margin-top: 15px; margin-bottom: 5px; }
        .scene-col-name { width: 40%; }
        .scene-col-id { width: 20%; }
        .scene-col-state { width: 40%; }
        .location-infographic-wrapper { text-align: center; max-width: 500px; margin: 0 auto; }
        .infographic-svg { border-radius: 5px; display: block; }
        .marker-container { position: absolute; top: 0; left: 0; width: 100%; height: 20px; }
        .location-svg { display: inline-block; width: 80%; }
        .invisible-col { border: none; background-color: transparent; }
        .rule-condition, .rule-action { background-color: #fff; border: 1px solid #eee; padding: 8px; margin: 5px 0; border-radius: 4px; font-family: "SF Mono", "Menlo", monospace; font-size: 0.9em; }
        code { white-space: pre-wrap; word-wrap: break-word; background-color: #eee; padding: 2px 4px; border-radius: 4px; }
    </style>
</head>
<body>
<div class="container">
    <h1 id="top">Philips Hue Assets Report</h1>
    <p class="report-meta">
        <strong>Bridge(s):</strong> $SELECTED_BRIDGE_NAME<br>
        <strong>Generated:</strong> $report_date
    </p>
EOF
    fi

    # --- Generate and Add Table of Contents ---
    if [[ "$report_generation_successful" == "true" ]]; then
        echo "--> Generating Table of Contents..."
        local toc_html
        toc_html=$(echo "$sorted_bridges_json" | jq -r '
            "<div class=\"toc\"><h2 class=\"toc-title\">Table of Contents</h2>" +
            (map(
                . as $bridge |
                ($bridge.bridge_name | gsub("[^a-zA-Z0-9_-]"; "-")) as $safe_bridge_name |
                # Create a list of light objects with their IDs for later processing
                ($bridge.lights | to_entries | map(.value + {light_id: .key})) as $lights_with_ids |
                ($bridge.groups | to_entries | reduce .[] as $group ({}; reduce $group.value.lights[] as $light_id (.; . + {($light_id): {name: $group.value.name, id: $group.key}}))) as $group_map_with_id |
                "<h3 class=\"bridge-group-title\"><a href=\"#bridge-" + .bridge_name + "\">" + .bridge_name + "</a></h3>" +
                "<ul>" +
                (
                    ($lights_with_ids | map(. + {groupName: ($group_map_with_id[.light_id].name // "Unassigned"), groupId: ($group_map_with_id[.light_id].id // "")}))
                    | group_by(.groupName)
                    | sort_by(.[0].groupName)
                    | map(
                        (if .[0].groupName == "Unassigned" then "" else "<li><a href=\"#" + $safe_bridge_name + "-group-" + (.[0].groupId) + "\"><strong>" + .[0].groupName + "</strong></a>" end) +
                        "<ul>" +
                        (sort_by(.name) | map("<li><a href=\"#light-" + .uniqueid + "\">" + .name + "</a></li>") | join("")) +
                        "</ul>" +
                        (if .[0].groupName == "Unassigned" then "" else "</li>" end)
                    ) | join("")
                ) +
                "</ul>" +
                "<ul>" +
                (if (.sensors|length) > 0 then "<li><a href=\"#sensors-" + .bridge_name + "\">Sensors (" + (.sensors|length|tostring) + ")</a></li>" else "" end) +
                (if (.schedules|length) > 0 then "<li><a href=\"#schedules-" + .bridge_name + "\">Schedules (" + (.schedules|length|tostring) + ")</a></li>" else "" end) +
                (if (.rules|length) > 0 then "<li><a href=\"#rules-" + .bridge_name + "\">Rules (" + (.rules|length|tostring) + ")</a></li>" else "" end) +
                (if (.resourcelinks|length) > 0 then "<li><a href=\"#resourcelinks-" + .bridge_name + "\">Resource Links (" + (.resourcelinks|length|tostring) + ")</a></li>" else "" end) +
                "</ul>"
            ) | join(""))
        ')
        if [[ $? -ne 0 ]]; then echo "Error: jq failed while generating Table of Contents." >&2; report_generation_successful=false; fi
    fi

    if [[ "$report_generation_successful" == "true" ]]; then
        local missing_serials_exist=false
        if [[ $(echo "$all_lights_json" | jq --argjson serials "$serials_json_content" '[.[] | select(($serials[.uniqueid].serialNumber // "") == "")] | length') -gt 0 ]]; then
            missing_serials_exist=true
        fi

        local unreachable_exist=false
        if [[ $(echo "$all_lights_json" | jq '[.[] | select(.state.reachable == false)] | length') -gt 0 ]]; then
            unreachable_exist=true
        fi

        if [[ "$missing_serials_exist" = true || "$unreachable_exist" = true ]]; then
            toc_html+="<h3 class=\"bridge-group-title\">Summaries</h3><ul>"
            if [[ "$missing_serials_exist" = true ]]; then
                toc_html+="<li><a href=\"#summary-missing-serials\">Lights with Missing Serial Numbers</a></li>"
            fi
            if [[ "$unreachable_exist" = true ]]; then
                toc_html+="<li><a href=\"#summary-unreachable\">Unreachable Lights</a></li>"
            fi
            toc_html+="</ul>"
        fi
        
        # Add Appendix to ToC
        toc_html+="<h3 class=\"bridge-group-title\">Reference</h3><ul>"
        toc_html+="<li><a href=\"#appendix-buttonevent\">Button Code Appendix</a></li>"
        toc_html+="<li><a href=\"#appendix-sensors\">System Sensor States Appendix</a></li>"
        toc_html+="</ul>"

        toc_html+="</div>"
        echo "$toc_html" >> "$output_html"
    fi

    local jq_functions='
        def brightness_infographic:
            if .bri != null then
                (((.bri // 0) | tonumber) / 254 * 100) as $percent |
                "<p class=\"detail-row\"><span class=\"label\">Brightness:</span> \($percent|round)%</p>" +
                "<div class=\"infographic\">" +
                "<svg width=\"100%\" height=\"40\" class=\"infographic-svg\">" +
                "<defs><linearGradient id=\"briGradient\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\"><stop offset=\"0%\" style=\"stop-color:#dddddd;\"/><stop offset=\"100%\" style=\"stop-color:#333333;\"/></linearGradient></defs>" +
                "<rect x=\"0\" y=\"0\" width=\"100%\" height=\"20\" fill=\"url(#briGradient)\" stroke=\"#cccccc\" stroke-width=\"1\"/>" +
                "<text x=\"0\" y=\"35\" font-size=\"10\">0%</text><text x=\"100%\" y=\"35\" text-anchor=\"end\" font-size=\"10\">100%</text>" +
                "</svg>" +
                "<div class=\"marker-container\"><div class=\"marker\" style=\"left: \($percent|tostring)%;\"></div></div>" +
                "</div>"
            else "" end;

        def ct_infographic:
            if .ct != null then
                ((.ct // 300) | tonumber) as $mired |
                (1000000 / $mired) as $kelvin |
                (($kelvin - 2000) / (6500 - 2000) * 100) as $percent_raw |
                (if $percent_raw < 0 then 0 elif $percent_raw > 100 then 100 else $percent_raw end) as $percent |
                "<p class=\"detail-row\"><span class=\"label\">Color Temp:</span> \($mired) Mired (approx. \($kelvin|round) K)</p>" +
                "<div class=\"infographic\">" +
                "<svg width=\"100%\" height=\"40\" class=\"infographic-svg\">" +
                "<defs><linearGradient id=\"tempGradient\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\"><stop offset=\"0%\" style=\"stop-color:#ff9a2e;\"/><stop offset=\"50%\" style=\"stop-color:#ffffff;\"/><stop offset=\"100%\" style=\"stop-color:#cce6ff;\"/></linearGradient></defs>" +
                "<rect x=\"0\" y=\"0\" width=\"100%\" height=\"20\" fill=\"url(#tempGradient)\" stroke=\"#cccccc\" stroke-width=\"1\"/>" +
                "<text x=\"0\" y=\"35\" font-size=\"10\">2000 K</text><text x=\"50%\" y=\"35\" text-anchor=\"middle\" font-size=\"10\">4250 K</text><text x=\"100%\" y=\"35\" text-anchor=\"end\" font-size=\"10\">6500 K</text>" +
                "</svg>" +
                "<div class=\"marker-container\"><div class=\"marker\" style=\"left: \($percent|tostring)%;\"></div></div>" +
                "</div>"
            else "" end;
        
        def hue_infographic:
            if .hue != null then
                (((.hue // 0) | tonumber) / 65535 * 100) as $percent |
                "<p class=\"detail-row\"><span class=\"label\">Hue:</span> \(.hue)</p>" +
                "<div class=\"infographic\">" +
                "<svg width=\"100%\" height=\"40\" class=\"infographic-svg\">" +
                "<defs><linearGradient id=\"hueGradient\"><stop offset=\"0%\" stop-color=\"hsl(0, 100%, 50%)\"/><stop offset=\"16.6%\" stop-color=\"hsl(60, 100%, 50%)\"/><stop offset=\"33.3%\" stop-color=\"hsl(120, 100%, 50%)\"/><stop offset=\"50%\" stop-color=\"hsl(180, 100%, 50%)\"/><stop offset=\"66.6%\" stop-color=\"hsl(240, 100%, 50%)\"/><stop offset=\"83.3%\" stop-color=\"hsl(300, 100%, 50%)\"/><stop offset=\"100%\" stop-color=\"hsl(360, 100%, 50%)\"/></linearGradient></defs>" +
                "<rect x=\"0\" y=\"0\" width=\"100%\" height=\"20\" fill=\"url(#hueGradient)\" stroke=\"#cccccc\" stroke-width=\"1\"/>" +
                "<text x=\"0\" y=\"35\" font-size=\"10\">0°</text><text x=\"50%\" y=\"35\" text-anchor=\"middle\" font-size=\"10\">180°</text><text x=\"100%\" y=\"35\" text-anchor=\"end\" font-size=\"10\">360°</text>" +
                "</svg>" +
                "<div class=\"marker-container\"><div class=\"marker\" style=\"left: \($percent|tostring)%;\"></div></div>" +
                "</div>"
            else "" end;

        def saturation_infographic:
            if .sat != null and .hue != null then
                (((.sat // 0) | tonumber) / 254 * 100) as $percent |
                (((.hue // 0) | tonumber) / 65535 * 360) as $hue_deg |
                "<p class=\"detail-row\"><span class=\"label\">Saturation:</span> \(.sat)</p>" +
                "<div class=\"infographic\">" +
                "<svg width=\"100%\" height=\"40\" class=\"infographic-svg\">" +
                "<defs><linearGradient id=\"satGradient-\($hue_deg)\"><stop offset=\"0%\" stop-color=\"hsl(\($hue_deg), 0%, 50%)\"/><stop offset=\"100%\" stop-color=\"hsl(\($hue_deg), 100%, 50%)\"/></linearGradient></defs>" +
                "<rect x=\"0\" y=\"0\" width=\"100%\" height=\"20\" fill=\"url(#satGradient-\($hue_deg))\" stroke=\"#cccccc\" stroke-width=\"1\"/>" +
                "<text x=\"0\" y=\"35\" font-size=\"10\">0%</text><text x=\"100%\" y=\"35\" text-anchor=\"end\" font-size=\"10\">100%</text>" +
                "</svg>" +
                "<div class=\"marker-container\"><div class=\"marker\" style=\"left: \($percent|tostring)%;\"></div></div>" +
                "</div>"
            else "" end;
        
        def xy_to_rgb_string:
            .xy[0] as $x | .xy[1] as $y | (((.bri // 127) | tonumber)/254) as $Y |
            (if $y == 0 then 0 else ($Y / $y) * $x end) as $X |
            (if $y == 0 then 0 else ($Y / $y) * (1 - $x - $y) end) as $Z |
            ($X * 1.656492 - $Y * 0.354851 - $Z * 0.255038) as $r_lin |
            (-$X * 0.707196 + $Y * 1.655397 + $Z * 0.036152) as $g_lin |
            ($X * 0.051713 - $Y * 0.121364 + $Z * 1.011530) as $b_lin |
            def gammacorrect: if . <= 0.0031308 then 12.92 * . else 1.055 * pow(.; (1.0/2.4)) - 0.055 end;
            ($r_lin | gammacorrect) as $r_corr | ($g_lin | gammacorrect) as $g_corr | ($b_lin | gammacorrect) as $b_corr |
            def clip: if . < 0 then 0 elif . > 1 then 1 else . end;
            ($r_corr | clip * 255 | round) as $r | ($g_corr | clip * 255 | round) as $g | ($b_corr | clip * 255 | round) as $b |
            "rgb(\($r),\($g),\($b))";

        def color_block:
            if .xy != null then
                "<div class=\"color-block-container\"><div class=\"color-block\" style=\"background-color: \(. | xy_to_rgb_string);\"></div></div>"
            elif .ct != null then
                ((.ct // 300) | tonumber) as $mired |
                ((($mired - 153) / (500 - 153)) | if . < 0 then 0 elif . > 1 then 1 else . end) as $p |
                (50 + $p * (40 - 50)) as $h | (10 + $p * (100 - 10)) as $s | (25 + (((.bri // 127) | tonumber) / 254 * 50)) as $l |
                "<div class=\"color-block-container\"><div class=\"color-block\" style=\"background-color: hsl(\($h | round), \($s | round)%, \($l | round)%);\"></div></div>"
            elif .hue != null then
                (((.hue // 0) | tonumber) / 65535 * 360) as $h | (((.sat // 0) | tonumber) / 254 * 100) as $s | (((.bri // 127) | tonumber) / 254 * 50) as $l |
                "<div class=\"color-block-container\"><div class=\"color-block\" style=\"background-color: hsl(\($h | round), \($s | round)%, \($l | round)%);\"></div></div>"
            else
                ((((.bri // 127) | tonumber) / 254 * 50) + 25) as $l_dim |
                "<div class=\"color-block-container\"><div class=\"color-block\" style=\"background-color: hsl(50, 80%, \($l_dim | round)%);\"></div></div>"
            end;

        def locations_infographic:
            def project($p):
                (100 + $p[0] * 40 - $p[1] * 40 | tostring) + "," + (75 + $p[0] * 20 + $p[1] * 20 - $p[2] * 40 | tostring);
            ([[-1,-1,0], [1,-1,0], [1,1,0], [-1,1,0], [-1,-1,1], [1,-1,1], [1,1,1], [-1,1,1]]) as $corners
            | ($corners | map(project(.) | split(",") | map(tonumber))) as $p_corners
            | "<div class=\"infographic location-infographic-wrapper\">" +
                "<svg viewBox=\"-30 0 260 150\" xmlns=\"http://www.w3.org/2000/svg\" class=\"location-svg\">" +
                ([ [0,1], [1,2], [2,3], [3,0], [4,5], [5,6], [6,7], [7,4], [0,4], [1,5], [2,6], [3,7] ] | map(
                "<line x1=\"\($p_corners[.[0]][0])\" y1=\"\($p_corners[.[0]][1])\" x2=\"\($p_corners[.[1]][0])\" y2=\"\($p_corners[.[1]][1])\" stroke=\"#ccc\" stroke-width=\"1\"/>"
                ) | join("")) +
                ( . | to_entries | map(
                .value as $coords | project($coords) as $p_coords |
                "<circle cx=\"\($p_coords | split(",")[0])\" cy=\"\($p_coords | split(",")[1])\" r=\"5\" fill=\"#005a9e\" stroke=\"white\" stroke-width=\"1\" />" +
                "<text x=\"\($p_coords | split(",")[0] | tonumber + 8)\" y=\"\($p_coords | split(",")[1] | tonumber + 4)\" font-size=\"10\" fill=\"#333\">#\(.key)</text>"
                ) | join("") ) +
                "</svg></div>";

        def scene_state_display:
            if . == null then "N/A" else
            "<div class=\"scene-state-container\">" +
                (if .on then "<span class=\"scene-status status-on\">ON</span>" else "<span class=\"scene-status status-off\">OFF</span>" end) +
                (if .bri != null then
                    ((((.bri // 0) | tonumber) / 254 * 100) as $p |
                    "<div class=\"mini-infographic-wrap\" title=\"Brightness: \($p|round)%\">" +
                    "<span>Bri:</span>" +
                    "<div class=\"mini-infographic bri-gradient\"><div class=\"mini-marker\" style=\"left: \($p)%;\"></div></div>" +
                    "</div>")
                else "" end) +
                (if .ct != null then
                    ((((((.ct // 300) | tonumber) - 153) / (500 - 153)) * 100) as $p_raw | (if $p_raw < 0 then 0 elif $p_raw > 100 then 100 else $p_raw end) as $p |
                    "<div class=\"mini-infographic-wrap\" title=\"Color Temp: \(.ct) Mired\">" +
                    "<span>CT:</span>" +
                    "<div class=\"mini-infographic ct-gradient\"><div class=\"mini-marker\" style=\"left: \($p)%;\"></div></div>" +
                    "</div>")
                else "" end) +
                (if .xy != null or .ct != null or .hue != null then (. | color_block) else "" end) +
            "</div>"
            end;
    '

    # --- Generate Main Report Body ---
    if [[ "$report_generation_successful" == "true" ]]; then
        echo "--> Generating Main Report Body..."
        while read -r bridge_obj; do
            local bridge_name
            bridge_name=$(echo "$bridge_obj" | jq -r '.bridge_name')
            echo "     - Processing Bridge: '$bridge_name'"

            bridge_info_html=$(echo "$bridge_obj" | jq -r '
                . as $bridge |
                "<div class=\"bridge-info\" id=\"bridge-\($bridge.bridge_name)\">" +
                "<p class=\"bridge-name\">" + $bridge.bridge_name + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">IP Address:</span> " + $bridge.bridge_ip + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">Username:</span> " + $bridge.bridge_user + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">Model ID:</span> " + $bridge.config.modelid + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">MAC Address:</span> " + $bridge.config.mac + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">Zigbee Channel:</span> " + ($bridge.config.zigbeechannel|tostring) + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">API Version:</span> " + $bridge.config.apiversion + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">Software Version:</span> " + $bridge.config.swversion + "</p>" +
                "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "</a></p>" +
                "</div>"
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing bridge info for $bridge_name" >&2; report_generation_successful=false; break; fi
            echo "$bridge_info_html" >> "$output_html"

            group_names_for_logging=$(echo "$bridge_obj" | jq -r '
                (.groups | to_entries | map(.value.name) | sort | .[]) as $group_name | "         - Processing Group: '\''\($group_name)'\''"
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed while logging group names for $bridge_name" >&2; report_generation_successful=false; break; fi

            if [[ -n "$group_names_for_logging" ]]; then
                echo "$group_names_for_logging"
            fi
            has_unassigned=$(echo "$bridge_obj" | jq '
                (.lights | to_entries | map(.value + {light_id: .key})) as $lights_with_ids |
                (.groups | to_entries | reduce .[] as $group ({}; reduce $group.value.lights[] as $light_id (.; .[$light_id] = true))) as $assigned_lights |
                [$lights_with_ids[] | select($assigned_lights[.light_id] | not)] | length > 0
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed while checking for unassigned lights in $bridge_name" >&2; report_generation_successful=false; break; fi

            if [[ "$has_unassigned" == "true" ]]; then
                echo "         - Processing Group: 'Unassigned'"
            fi

            all_groups_and_lights_html=$(echo "$bridge_obj" | jq --argjson serials "$serials_json_content" -r "$jq_functions"'
                . as $bridge |
                ($bridge.bridge_name | gsub("[^a-zA-Z0-9_-]"; "-")) as $safe_bridge_name |
                ($bridge.lights | to_entries | map(.value + {light_id: .key})) as $lights_with_ids |
                (.groups | to_entries | reduce .[] as $group ({}; reduce $group.value.lights[] as $light_id (.; .[$light_id] += [{name: $group.value.name, id: $group.key}]))) as $light_to_groups_map |
                ($lights_with_ids | reduce .[] as $light ({}; . + {($light.light_id): {name: $light.name, uniqueid: $light.uniqueid}})) as $light_id_to_details_map |
                ($bridge.scenes | to_entries | reduce .[] as $scene ({}; reduce ($scene.value.lights // [])[] as $light_id (.; .[$light_id] += [{name: $scene.value.name, id: $scene.key}]))) as $light_to_scenes_map |

                ([.groups | to_entries[] | {id: .key, value: .value}] | sort_by(.value.name)) as $sorted_groups_raw |
                (
                    if ([ $lights_with_ids[] | select(($light_to_groups_map[.light_id] | length // 0) == 0)] | length) > 0 then
                        $sorted_groups_raw + [{"id": "unassigned", "value": {"name": "Unassigned", "lights": [], "type": "System"}}]
                    else
                        $sorted_groups_raw
                    end
                ) as $sorted_groups |

                ($sorted_groups | map(
                    . as $group_info |
                    (
                        if $group_info.value.name != "Unassigned" then
                            "<div class=\"group-info\" id=\"\($safe_bridge_name)-group-\($group_info.id)\">" +
                            "<p class=\"group-name\">Room/Zone: " + $group_info.value.name + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Type:</span> " + $group_info.value.type + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Class:</span> " + $group_info.value.class + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Group ID:</span> " + $group_info.id + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/groups/" + $group_info.id + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/.../groups/" + $group_info.id + "</a></p>" +
                            "<p class=\"detail-row section-header\">Last Action State</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">State:</span> " + (if $group_info.value.action.on then "On" else "Off" end) + "</p>" +
                            (if $group_info.value.action.on then ($group_info.value.action | brightness_infographic) else "" end) +
                            (if $group_info.value.action.on then ($group_info.value.action | ct_infographic) else "" end) +
                            (if $group_info.value.action.on and ($group_info.value.action.colormode // "") == "hs" then ($group_info.value.action | hue_infographic) else "" end) +
                            (if $group_info.value.action.on and ($group_info.value.action.colormode // "") == "hs" then ($group_info.value.action | saturation_infographic) else "" end) +
                            (if $group_info.value.action.on and ($group_info.value.action.colormode // "") == "xy" then "<p class=\"detail-row\"><span class=\"label\">XY Color:</span> [\($group_info.value.action.xy[0]|tostring), \($group_info.value.action.xy[1]|tostring)]</p>" else "" end) +
                            (if $group_info.value.action.on then "<p class=\"detail-row\"><span class=\"label\">Color:</span></p>" + ($group_info.value.action | color_block) else "" end) +
                            (if $group_info.value.type == "Entertainment" and ($group_info.value.locations | length > 0) then
                                "<p class=\"detail-row section-header\">Light Locations</p>" +
                                ($group_info.value.locations | locations_infographic) +
                                "<table>" +
                                "<tr><th>Light Name</th><th>ID</th><th>Coordinates (X, Y, Z)</th></tr>" +
                                ($group_info.value.locations | to_entries | map( "<tr><td><a href=\"#light-" + ($light_id_to_details_map[.key].uniqueid // "") + "\">" + ($light_id_to_details_map[.key].name // .key) + "</a></td><td>" + .key + "</td><td>" + (.value | map(tostring) | join(", ")) + "</td></tr>" ) | join("")) + "</table>"
                            elif ($group_info.value.lights | length > 0) then
                                "<p class=\"detail-row section-header\">Lights in this Group</p>" +
                                "<table>" + "<tr><th class=\"scene-col-name\">Light Name</th><th class=\"scene-col-id\">ID</th><th class=\"invisible-col\"></th></tr>" + ($group_info.value.lights | map( . as $light_id | $light_id_to_details_map[$light_id] as $light_details | "<tr><td><a href=\"#light-\($light_details.uniqueid // "")\">" + ($light_details.name // $light_id) + "</a></td><td>" + $light_id + "</td><td class=\"invisible-col\"></td></tr>" ) | join("")) + "</table>"
                            else "" end) +
                            ( $bridge.scenes | to_entries | map(select(.value.type == "GroupScene" and .value.group == $group_info.id)) | if length > 0 then "<p class=\"detail-row section-header\">Group Scenes</p>" + (map( . as $scene | "<h4 class=\"scene-title\" id=\"\($safe_bridge_name)-scene-\($scene.key)\"><a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/scenes/" + $scene.key + "\" target=\"_blank\">" + $scene.value.name + "</a></h4>" + "<table>" + "<tr><th class=\"scene-col-name\">Light Name</th><th class=\"scene-col-id\">ID</th><th class=\"scene-col-state\">Scene State</th></tr>" + ( $scene.value.lights | map( . as $light_id | $light_id_to_details_map[$light_id] as $light_details | (($scene.value.lightstates // {})[$light_id] // $scene.value.action) as $light_state | "<tr><td><a href=\"#light-\($light_details.uniqueid // "")\">" + ($light_details.name // $light_id) + "</a></td><td>" + $light_id + "</td><td>\($light_state | scene_state_display)</td></tr>" ) | join("")) + "</table>" ) | join("")) else "" end ) + "</div>"
                        else "" end
                    ) +
                    (
                        ($lights_with_ids
                        | map(select((($light_to_groups_map[.light_id] | map(.name) // ["Unassigned"]) | index($group_info.value.name)) != null))
                        | sort_by(.name) | map(
                            . as $light |
                            "<div class=\"light-entry\" id=\"light-\($light.uniqueid)\">" +
                                "<p class=\"light-name\">" + $light.name + "</p>" +
                                "<p class=\"detail-row section-header\">Basic Info</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Product Name:</span> <a href=\"https://www.google.com/search?q=Philips+Hue+" + (($light.productname // "") | gsub(" "; "+")) + "\" target=\"_blank\">" + ($light.productname // "N/A") + "</a></p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Model ID:</span> <a href=\"https://www.google.com/search?q=Philips+Hue+" + (($light.modelid // "") | gsub(" "; "+")) + "\" target=\"_blank\">" + ($light.modelid // "N/A") + "</a></p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Type:</span> " + ($light.type // "N/A") + "</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Group/Room(s):</span> " + ($light_to_groups_map[$light.light_id] | if . then (sort_by(.name) | map("<a href=\"#\($safe_bridge_name)-group-\(.id)\">" + .name + "</a>") | join(", ")) else "Unassigned" end) + "</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Scene(s):</span> " + ($light_to_scenes_map[$light.light_id] | if . then (sort_by(.name) | map("<a href=\"#\($safe_bridge_name)-scene-\(.id)\">" + .name + "</a>") | join(", ")) else "None" end) + "</p>" +
                                "<p class=\"detail-row section-header\">Current State</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Status:</span> " + (if $light.state.reachable then "<span class=\"reachable\">Reachable</span>" else "<span class=\"unreachable\">UNREACHABLE</span>" end) + ", " + (if $light.state.on then "<span class=\"on\">On</span>" else "<span class=\"off\">Off</span>" end) + "</p>" +
                                "<p class=\"detail-row section-header\">Last Known State</p>" +
                                (.state | brightness_infographic) + (if .state.colormode // "" == "hs" then (.state | hue_infographic) else "" end) + (if .state.colormode // "" == "hs" then (.state | saturation_infographic) else "" end) + (.state | ct_infographic) + (if .state.colormode // "" == "xy" then "<p class=\"detail-row\"><span class=\"label\">XY Color:</span> [\((.state.xy[0]|tostring)), \((.state.xy[1]|tostring))]</p>" else "" end) +
                                "<p class=\"detail-row\"><span class=\"label\">Color:</span></p>" + (.state | color_block) +
                                "<p class=\"detail-row section-header\">Technical Info</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Light ID:</span> " + ($light.light_id // "N/A") + "</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Serial Number:</span> " + (if ($serials[$light.uniqueid].serialNumber // "") == "" then "N/A" else $serials[$light.uniqueid].serialNumber end) + "</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Product ID:</span> " + (if $light.productid then "<a href=\"https://www.google.com/search?q=Philips+Hue+" + (($light.productid // "") | gsub(" "; "+")) + "\" target=\"_blank\">" + $light.productid + "</a>" else "N/A" end) + "</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">Unique ID:</span> " + ($light.uniqueid // "N/A") + "</p>" +
                                "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/lights/" + $light.light_id + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/.../lights/" + $light.light_id + "</a></p>" +
                                "<p class=\"detail-row section-header\">ToC</p><p class=\"detail-row\"><a href=\"#top\">Jump to Top</a></p>" +
                            "</div>"
                        ) | join(""))
                    )
                ) | join(""))
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing lights/groups for $bridge_name" >&2; report_generation_successful=false; break; fi
            echo "$all_groups_and_lights_html" >> "$output_html"

            sensors_html=$(echo "$bridge_obj" | jq -r '
                . as $bridge |
                ($bridge.bridge_name | gsub("[^a-zA-Z0-9_-]"; "-")) as $safe_bridge_name |
                if ($bridge.sensors | length) > 0 then
                    "<h2 class=\"summary-title\" id=\"sensors-\($bridge.bridge_name)\">Sensors</h2>" +
                    (
                        $bridge.sensors | to_entries | sort_by(.value.name) | map(
                            . as $sensor |
                            "<div class=\"sensor-info\" id=\"\($safe_bridge_name)-sensor-\($sensor.key)\">" +
                            "<p class=\"sensor-name\">" + $sensor.value.name + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">ID:</span> " + $sensor.key + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Type:</span> " + $sensor.value.type + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Model ID:</span> " + ($sensor.value.modelid // "N/A") + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Product:</span> " + ($sensor.value.productname // "N/A") + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Manufacturer:</span> " + ($sensor.value.manufacturername // "N/A") + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">On/Off Status:</span> " + (($sensor.value.config.on | tostring) // "N/A") + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Reachable:</span> " + (($sensor.value.config.reachable | tostring) // "N/A") + "</p>" +
                            (if $sensor.value.config.battery != null then "<p class=\"detail-row\"><span class=\"label\">Battery:</span> " + ($sensor.value.config.battery|tostring) + "%</p>" else "" end) +
                            "<p class=\"detail-row section-header\">Current State</p>" +
                            ($sensor.value.state | to_entries | map("<p class=\"detail-row\"><span class=\"label\">" + .key + ":</span> " + (.value|tostring) + "</p>") | join("")) +
                            "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/sensors/" + $sensor.key + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/.../sensors/" + $sensor.key + "</a></p>" +
                            "<p class=\"detail-row section-header\">ToC</p><p class=\"detail-row\"><a href=\"#top\">Jump to Top</a></p>" +
                            "</div>"
                        ) | join("")
                    )
                else "" end
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing sensors for $bridge_name" >&2; report_generation_successful=false; break; fi
            echo "$sensors_html" >> "$output_html"

            schedules_html=$(echo "$bridge_obj" | jq -r '
                . as $bridge |
                ($bridge.bridge_name | gsub("[^a-zA-Z0-9_-]"; "-")) as $safe_bridge_name |
                if ($bridge.schedules | length) > 0 then
                    "<h2 class=\"summary-title\" id=\"schedules-\($bridge.bridge_name)\">Schedules</h2>" +
                    (
                        $bridge.schedules | to_entries | sort_by(.value.name) | map(
                            . as $schedule |
                            "<div class=\"schedule-info\" id=\"\($safe_bridge_name)-schedule-\($schedule.key)\">" +
                            "<p class=\"schedule-name\">" + $schedule.value.name + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">ID:</span> " + $schedule.key + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Description:</span> " + $schedule.value.description + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Local Time:</span> " + $schedule.value.localtime + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Status:</span> " + $schedule.value.status + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Created:</span> " + $schedule.value.created + "</p>" +
                            "<p class=\"detail-row section-header\">Command</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Address:</span> <code>" + $schedule.value.command.address + "</code></p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Method:</span> " + $schedule.value.command.method + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Body:</span> <pre style=\"white-space: pre-wrap; word-wrap: break-word; background-color: #eee; padding: 5px; border-radius: 4px;\">" + ($schedule.value.command.body|tojson) + "</pre></p>" +
                            "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/schedules/" + $schedule.key + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/.../schedules/" + $schedule.key + "</a></p>" +
                            "<p class=\"detail-row section-header\">ToC</p><p class=\"detail-row\"><a href=\"#top\">Jump to Top</a></p>" +
                            "</div>"
                        ) | join("")
                    )
                else "" end
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing schedules for $bridge_name" >&2; report_generation_successful=false; break; fi
            echo "$schedules_html" >> "$output_html"

            rules_html=$(echo "$bridge_obj" | jq -r '
                . as $bridge |
                ($bridge.bridge_name | gsub("[^a-zA-Z0-9_-]"; "-")) as $safe_bridge_name |
                ($bridge.scenes | to_entries | map({key: .key, value: .value.name}) | from_entries) as $scenes_map |
                ($bridge.sensors | to_entries | map({key: .key, value: .value.name}) | from_entries) as $sensors_map |
                ($bridge.groups | to_entries | map({key: .key, value: .value.name}) | from_entries) as $groups_map |
                ($bridge.schedules | to_entries | map({key: .key, value: .value.name}) | from_entries) as $schedules_map |

                # --- Helper function to decode schedule localtime ---
                def decode_localtime:
                    if . == null then ""
                    elif . | startswith("P") then
                        # Duration, e.g., PT00:00:10
                        (. | capture("PT(?:(?<h>\\d+)H)?(?:(?<m>\\d+)M)?(?:(?<s>\\d+)S)?") // {}) as $d |
                        "Set a timer to run in " + (
                            [
                                (if $d.h then "\($d.h) hour(s)" else null end),
                                (if $d.m then "\($d.m) minute(s)" else null end),
                                (if $d.s then "\($d.s) second(s)" else null end)
                            ] | del(..|nulls) | join(", ")
                        )
                    elif . | contains("W") then
                        # Recurring, e.g., W127/T18:00:00
                        (. | capture("W(?<days>\\d+)/T(?<time>.+)")) as $r |
                        ($r.days | tonumber) as $mask |
                        ( [
                            (if ($mask / 64 | floor) % 2 == 1 then "Mon" else null end),
                            (if ($mask / 32 | floor) % 2 == 1 then "Tue" else null end),
                            (if ($mask / 16 | floor) % 2 == 1 then "Wed" else null end),
                            (if ($mask / 8 | floor) % 2 == 1 then "Thu" else null end),
                            (if ($mask / 4 | floor) % 2 == 1 then "Fri" else null end),
                            (if ($mask / 2 | floor) % 2 == 1 then "Sat" else null end),
                            (if ($mask / 1 | floor) % 2 == 1 then "Sun" else null end)
                            ] | del(..|nulls) ) as $days_arr |
                        "Set to run at <b>\($r.time)</b> on " +
                        (if ($days_arr|length) == 7 then "<b>every day</b>" else "<b>\($days_arr | join(", "))</b>" end)
                    else
                        # Absolute, e.g., 2025-09-21T10:30:00
                        "Set to run at <b>\(.)</b>"
                    end;

                def op_to_words(op):
                    ({
                        "eq": "is equal to",
                        "gt": "is greater than",
                        "lt": "is less than",
                        "dx": "changes",
                        "ddx": "changes for a duration of",
                        "stable": "is stable for a duration of",
                        "in": "is in the range",
                        "not in": "is not in the range"
                    }[op] // op);

                def decode_buttonevent(code; sensor_name):
                    (if sensor_name then " on '"'"'<b>\(sensor_name)</b>'"'"'" else "" end) as $name_part |
                    if code == 34 then "Hue Tap Button 1\($name_part) is pressed"
                    elif code == 16 then "Hue Tap Button 2\($name_part) is pressed"
                    elif code == 17 then "Hue Tap Button 3\($name_part) is pressed"
                    elif code == 18 then "Hue Tap Button 4\($name_part) is pressed"
                    elif code >= 1000 and code <= 4999 then
                        (code | tostring) as $codestr |
                        ($codestr[0:1]) as $button_code |
                        ($codestr[3:4]) as $action_code |
                        ({
                            "1": "the '"'"'On'"'"' / Smart / Upper button",
                            "2": "the '"'"'Dim Up'"'"' / Lower button",
                            "3": "the '"'"'Dim Down'"'"' button",
                            "4": "the '"'"'Off'"'"' button"
                        }[$button_code] // "an unknown button") as $button_name |
                        ({
                            "0": "is initially pressed",
                            "1": "is held down",
                            "2": "is short-released",
                            "3": "is long-released"
                        }[$action_code] // "has an unknown action") as $action_desc |
                        "\($button_name)\($name_part) \($action_desc)"
                    else
                        "received an unknown event code (\(code))\($name_part)"
                    end;

                def format_condition:
                    . as $cond |
                    ($cond.address | split("/") | .[2]) as $split_addr_id |
                    (
                        [
                            (if ($cond.address | contains("groups/")) and $split_addr_id and $groups_map[$split_addr_id]
                            then {html: "<i>(Group: <a href=\"#\($safe_bridge_name)-group-\($split_addr_id)\">\($groups_map[$split_addr_id])</a>)</i>", name: $groups_map[$split_addr_id]} else empty end),
                            (if ($cond.address | contains("scenes/")) and $split_addr_id and $scenes_map[$split_addr_id]
                            then {html: "<i>(Scene: <a href=\"#\($safe_bridge_name)-scene-\($split_addr_id)\">\($scenes_map[$split_addr_id])</a>)</i>", name: $scenes_map[$split_addr_id]} else empty end),
                            (if ($cond.address | contains("sensors/")) and $split_addr_id and $sensors_map[$split_addr_id]
                            then {html: "<i>(Sensor: <a href=\"#\($safe_bridge_name)-sensor-\($split_addr_id)\">\($sensors_map[$split_addr_id])</a>)</i>", name: $sensors_map[$split_addr_id]} else empty end),
                            (if ($cond.address | contains("schedules/")) and $split_addr_id and $schedules_map[$split_addr_id]
                            then {html: "<i>(Schedule: <a href=\"#\($safe_bridge_name)-schedule-\($split_addr_id)\">\($schedules_map[$split_addr_id])</a>)</i>", name: $schedules_map[$split_addr_id]} else empty end)
                        ] | .[0] // {html: "", name: null}
                    ) as $item_info |
                    (
                        ($cond.address | capture("/(state|config)/(?<attr>.+)$") | .attr // null) as $attribute |
                        ($item_info.name) as $item_name |
                        (op_to_words($cond.operator)) as $operator_words |
                        if $item_name and $attribute then
                            (
                                if $attribute == "buttonevent" and $cond.operator == "eq" then
                                    ($cond.value | tonumber) as $code |
                                    "If <a href=\"#code-\($code)\">" + (decode_buttonevent($code; $item_name)) + "</a>"
                                # --- NEW: Intelligent handling of dynamic scene sensors ---
                                elif $item_name == "cycleState" and $attribute == "status" and $cond.operator == "eq" and ($cond.value | tonumber) == 0 then
                                    "If <a href=\"#appendix-sensors\">dynamic scenes are inactive</a>"
                                elif $item_name == "cycleState" and $attribute == "status" and $cond.operator == "eq" and ($cond.value | tonumber) == 1 then
                                    "If <a href=\"#appendix-sensors\">a dynamic scene is active</a>"
                                elif $item_name == "cycleState" and $attribute == "status" and $cond.operator == "eq" and ($cond.value | tonumber) == 2 then
                                    "If <a href=\"#appendix-sensors\">a dynamic scene is active and set to update speed</a>"
                                elif $item_name == "cycleState" and $attribute == "status" and $cond.operator == "eq" and ($cond.value | tonumber) == 3 then
                                    "If <a href=\"#appendix-sensors\">a dynamic scene is in an undocumented '3' state</a>"
                                elif $item_name == "cycleState" and $attribute == "status" and $cond.operator == "eq" and ($cond.value | tonumber) == 4 then
                                    "If <a href=\"#appendix-sensors\">the dynamic scene is set to a fixed color</a>"
                                elif $item_name == "cycleState" and $attribute == "status" and $cond.operator == "eq" and ($cond.value | tonumber) == 5 then
                                    "If <a href=\"#appendix-sensors\">the dynamic scene is set to random colors</a>"
                                elif $item_name == "cycling" and $attribute == "status" and (($cond.operator == "lt" and ($cond.value | tonumber) == 1) or ($cond.operator == "eq" and ($cond.value | tonumber) == 0)) then
                                    "If <a href=\"#appendix-sensors\">no dynamic scene is active</a>"
                                elif $item_name == "cycling" and $attribute == "status" and $cond.operator == "gt" and ($cond.value | tonumber) == 0 then
                                    "If <a href=\"#appendix-sensors\">a dynamic scene is currently active</a>"
                                elif $cond.operator == "dx" then
                                    "If <b>" + $item_name + "</b>'"'"'s " + $attribute + " " + $operator_words
                                else
                                    "If <b>" + $item_name + "</b>'"'"'s " + $attribute + " " + $operator_words + " <b>" + ($cond.value | tostring) + "</b>"
                                end
                            ) + "... Then"
                        else null
                        end
                    ) as $sentence_html |
                    "<div class=\"rule-condition\">" +
                    "Address: <code>" + $cond.address + "</code>" +
                    (if $item_info.html != "" then "<br>" + $item_info.html else "" end) +
                    "<br>Operator: <b>" + $cond.operator + "</b><br>" +
                    "Value: <code>" + ($cond.value|tostring) + "</code>" +
                    (if $sentence_html then "<br><br><i>" + $sentence_html + "</i>" else "" end) +
                    "</div>";

                def format_body_part(item_name; item_type):
                    .key as $k | .value as $v |
                    if $k == "on" and $v == true then "Turn on <b>\(item_name)</b>"
                    elif $k == "on" and $v == false then "Turn off <b>\(item_name)</b>"
                    elif $k == "bri" then "Set brightness to <b>\(($v / 254 * 100) | round)%</b>"
                    elif $k == "ct" then "Set color temperature to <b>\($v) Mired</b>"
                    elif $k == "hue" then "Set hue to <b>\($v)</b>"
                    elif $k == "sat" then "Set saturation to <b>\($v)</b>"
                    elif $k == "xy" then "Set color to xy <b>[\($v | join(", "))]</b>"
                    elif $k == "alert" then "Set alert to <b>\($v)</b>"
                    elif $k == "effect" then "Set effect to <b>\($v)</b>"
                    elif $k == "transitiontime" then "Set transition time to <b>\(($v / 10))s</b>"
                    elif $k == "scene" and $scenes_map[$v] then "Activate scene <b><a href=\"#\($safe_bridge_name)-scene-\($v)\">\($scenes_map[$v])</a></b>"
                    # --- NEW: Intelligent handling of schedule and dynamic scene actions ---
                    elif item_type == "schedule" and $k == "status" then (if $v == "enabled" then "Enable" else "Disable" end) + " the schedule <b>\(item_name)</b>"
                    elif item_type == "schedule" and $k == "localtime" then "\($v | decode_localtime) for schedule <b>\(item_name)</b>"
                    elif item_name == "cycling" and $k == "status" and $v == 0 then "<a href=\"#appendix-sensors\">Stop the current color cycle</a>"
                    elif item_name == "cycleState" and $k == "status" and $v == 0 then "<a href=\"#appendix-sensors\">Stop the dynamic scene</a>"
                    elif item_name == "cycleState" and $k == "status" and $v == 1 then "<a href=\"#appendix-sensors\">Start the dynamic scene</a>"
                    elif item_name == "cycleState" and $k == "status" and $v == 2 then "<a href=\"#appendix-sensors\">Update the speed of the active dynamic scene</a>"
                    elif item_name == "cycleState" and $k == "status" and $v == 3 then "<a href=\"#appendix-sensors\">Set dynamic scene to an undocumented '3' state</a>"
                    elif item_name == "cycleState" and $k == "status" and $v == 4 then "<a href=\"#appendix-sensors\">Set dynamic scene to a fixed color</a>"
                    elif item_name == "cycleState" and $k == "status" and $v == 5 then "<a href=\"#appendix-sensors\">Set dynamic scene to random colors</a>"
                    else "Set <b>\(item_name)</b>'"'"'s \($k) to <b>\($v | tostring)</b>"
                    end;

                def format_action:
                    . as $action |
                    ($action.address | split("/") | .[2]) as $split_addr_id |
                    (
                        [
                            (if ($action.address | contains("groups/")) and $split_addr_id and $groups_map[$split_addr_id]
                            then {html: "<i>(Group: <a href=\"#\($safe_bridge_name)-group-\($split_addr_id)\">\($groups_map[$split_addr_id])</a>)</i>", name: $groups_map[$split_addr_id], type: "group"} else empty end),
                            (if ($action.address | contains("sensors/")) and $split_addr_id and $sensors_map[$split_addr_id]
                            then {html: "<i>(Sensor: <a href=\"#\($safe_bridge_name)-sensor-\($split_addr_id)\">\($sensors_map[$split_addr_id])</a>)</i>", name: $sensors_map[$split_addr_id], type: "sensor"} else empty end),
                            (if ($action.address | contains("schedules/")) and $split_addr_id and $schedules_map[$split_addr_id]
                            then {html: "<i>(Schedule: <a href=\"#\($safe_bridge_name)-schedule-\($split_addr_id)\">\($schedules_map[$split_addr_id])</a>)</i>", name: $schedules_map[$split_addr_id], type: "schedule"} else empty end)
                        ] | .[0] // {html: "", name: "target", type: "unknown"}
                    ) as $item_info |
                    (
                        $action.body | to_entries | map(format_body_part($item_info.name; $item_info.type)) | join("<br>")
                    ) as $interpretation |
                    "<div class=\"rule-action\">" +
                    "Address: <code>" + .address + "</code>" +
                    (if $item_info.html != "" then "<br>" + $item_info.html else "" end) +
                    "<br>Method: <b>" + .method + "</b><br>" +
                    "Body: <code>" + (.body|tojson) + "</code>" +
                    (if .body.scene and $scenes_map[.body.scene] then " <i>(Scene: <a href=\"#\($safe_bridge_name)-scene-\(.body.scene)\">\($scenes_map[.body.scene])</a>)</i>" else "" end) +
                    (if $interpretation != "" then "<br><br><i>" + $interpretation + "</i>" else "" end) +
                    "</div>";

                if ($bridge.rules | length) > 0 then
                    "<h2 class=\"summary-title\" id=\"rules-\($bridge.bridge_name)\">Rules</h2>" +
                    (
                        $bridge.rules | to_entries | sort_by(.value.name) | map(
                            . as $rule |
                            "<div class=\"rule-info\" id=\"\($safe_bridge_name)-rule-\($rule.key)\">" +
                            "<p class=\"rule-name\">" + .value.name + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">ID:</span> " + $rule.key + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Status:</span> " + .value.status + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Created:</span> " + .value.created + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Last Triggered:</span> " + .value.lasttriggered + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Times Triggered:</span> " + (.value.timestriggered|tostring) + "</p>" +
                            "<p class=\"detail-row section-header\">Logic</p>" +
                            "<b>Conditions:</b>" + (.value.conditions | map(format_condition) | join("")) +
                            "<b>Actions:</b>" + (.value.actions | map(format_action) | join("")) +
                            "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/rules/" + $rule.key + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/.../rules/" + $rule.key + "</a></p>" +
                            "<p class=\"detail-row section-header\">ToC</p><p class=\"detail-row\"><a href=\"#top\">Jump to Top</a></p>" +
                            "</div>"
                        ) | join("")
                    )
                else "" end
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing rules for $bridge_name" >&2; report_generation_successful=false; break; fi
            echo "$rules_html" >> "$output_html"

            resourcelinks_html=$(echo "$bridge_obj" | jq -r '
                . as $bridge |
                ($bridge.bridge_name | gsub("[^a-zA-Z0-9_-]"; "-")) as $safe_bridge_name |
                ($bridge.scenes | to_entries | map({key: .key, value: .value.name}) | from_entries) as $scenes_map |
                ($bridge.sensors | to_entries | map({key: .key, value: .value.name}) | from_entries) as $sensors_map |
                ($bridge.groups | to_entries | map({key: .key, value: .value.name}) | from_entries) as $groups_map |
                ($bridge.rules | to_entries | map({key: .key, value: .value.name}) | from_entries) as $rules_map |

                if ($bridge.resourcelinks | length) > 0 then
                    "<h2 class=\"summary-title\" id=\"resourcelinks-\($bridge.bridge_name)\">Resource Links</h2>" +
                    (
                        $bridge.resourcelinks | to_entries | sort_by(.value.name) | map(
                            . as $link |
                            "<div class=\"resourcelink-info\" id=\"\($safe_bridge_name)-resourcelink-\($link.key)\">" +
                            "<p class=\"resourcelink-name\">" + $link.value.name + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">ID:</span> " + $link.key + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Description:</span> " + $link.value.description + "</p>" +
                            "<p class=\"detail-row\"><span class=\"label\">Owner:</span> " + ($link.value.owner // "N/A") + "</p>" +
                            "<p class=\"detail-row section-header\">Links</p>" +
                            "<ul>" +
                            (
                                $link.value.links | map(
                                    . as $link_path |
                                    ($link_path | capture("^/(?<type>\\w+)/(?<id>.+)$") // null) as $parts |
                                    (
                                        if $parts == null then ""
                                        elif $parts.type == "groups" and $groups_map[$parts.id] then
                                            " <i>(Group: <a href=\"#\($safe_bridge_name)-group-\($parts.id)\">\($groups_map[$parts.id])</a>)</i>"
                                        elif $parts.type == "scenes" and $scenes_map[$parts.id] then
                                            " <i>(Scene: <a href=\"#\($safe_bridge_name)-scene-\($parts.id)\">\($scenes_map[$parts.id])</a>)</i>"
                                        elif $parts.type == "sensors" and $sensors_map[$parts.id] then
                                            " <i>(Sensor: <a href=\"#\($safe_bridge_name)-sensor-\($parts.id)\">\($sensors_map[$parts.id])</a>)</i>"
                                        elif $parts.type == "rules" and $rules_map[$parts.id] then
                                            " <i>(Rule: <a href=\"#\($safe_bridge_name)-rule-\($parts.id)\">\($rules_map[$parts.id])</a>)</i>"
                                        else ""
                                        end
                                    ) as $annotation |
                                    "<li><code>" + $link_path + "</code>" + $annotation + "</li>"
                                ) | join("")
                            ) +
                            "</ul>" +
                            "<p class=\"detail-row\"><span class=\"label\">API URL:</span> <a href=\"http://" + $bridge.bridge_ip + "/api/" + $bridge.bridge_user + "/resourcelinks/" + $link.key + "\" target=\"_blank\">http://" + $bridge.bridge_ip + "/api/.../resourcelinks/" + $link.key + "</a></p>" +
                            "<p class=\"detail-row section-header\">ToC</p><p class=\"detail-row\"><a href=\"#top\">Jump to Top</a></p>" +
                            "</div>"
                        ) | join("")
                    )
                else "" end
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing resourcelinks for $bridge_name" >&2; report_generation_successful=false; break; fi
            echo "$resourcelinks_html" >> "$output_html"

        done < <(echo "$sorted_bridges_json" | jq -c '.[]')
    fi

    # --- Add Summary Sections ---
    if [[ "$report_generation_successful" == "true" ]]; then
        echo "--> Generating Summary Sections..."
        missing_serials_summary=$(echo "$all_lights_json" | jq --argjson serials "$serials_json_content" -r '
            map(select(($serials[.uniqueid].serialNumber // "") == ""))
            | group_by(.bridgeName)
            | if length > 0 then
                "<h2 class=\"summary-title\" id=\"summary-missing-serials\">Lights with Missing Serial Numbers</h2>" +
                (map( "<h3 class=\"bridge-group-title\">" + .[0].bridgeName + "</h3>" + "<ul>" + (map("<li>" + .name + "</li>") | join("")) + "</ul>" ) | join(""))
            else "" end
        ')
        if [[ $? -ne 0 ]]; then echo "Error: jq failed processing missing serials summary." >&2; report_generation_successful=false; fi
        
        if [[ "$report_generation_successful" == "true" ]]; then
            unreachable_lights_summary=$(echo "$all_lights_json" | jq -r '
                map(select(.state.reachable == false))
                | group_by(.bridgeName)
                | if length > 0 then
                    "<h2 class=\"summary-title\" id=\"summary-unreachable\">Unreachable Lights</h2>" +
                    (map( "<h3 class=\"bridge-group-title\">" + .[0].bridgeName + "</h3>" + "<ul>" + (map("<li>" + .name + "</li>") | join("")) + "</ul>" ) | join(""))
                else "" end
            ')
            if [[ $? -ne 0 ]]; then echo "Error: jq failed processing unreachable lights summary." >&2; report_generation_successful=false; fi
        fi

        if [[ "$report_generation_successful" == "true" ]]; then
            if [[ -n "$missing_serials_summary" ]]; then
                echo "$missing_serials_summary" >> "$output_html"
            fi
            if [[ -n "$unreachable_lights_summary" ]]; then
                echo "$unreachable_lights_summary" >> "$output_html"
            fi
        fi
    fi

    # --- FINAL WRAP-UP ---
    if [[ "$report_generation_successful" == "true" ]]; then
        # Add Appendix Section
        echo "--> Generating Appendix..."
        cat << 'EOF' >> "$output_html"
<h2 class="summary-title" id="appendix-buttonevent">Appendix: Button Event Codes</h2>
<p>This table lists all known <code>buttonevent</code> codes and their meanings for various Hue devices. Click a rule's decoded condition to jump here.</p>
<table>
  <thead>
    <tr>
      <th>Code</th>
      <th>Device</th>
      <th>Button</th>
      <th>Action</th>
    </tr>
  </thead>
  <tbody>
    <tr id="code-1000"><td>1000</td><td>Dimmer / Smart Button / Wall Switch</td><td>On / Smart / Upper</td><td>Initial Press</td></tr>
    <tr id="code-1001"><td>1001</td><td>Dimmer / Smart Button / Wall Switch</td><td>On / Smart / Upper</td><td>Hold</td></tr>
    <tr id="code-1002"><td>1002</td><td>Dimmer / Smart Button / Wall Switch</td><td>On / Smart / Upper</td><td>Short Release</td></tr>
    <tr id="code-1003"><td>1003</td><td>Dimmer / Smart Button / Wall Switch</td><td>On / Smart / Upper</td><td>Long Release</td></tr>
    <tr id="code-2000"><td>2000</td><td>Dimmer / Wall Switch</td><td>Dim Up / Lower</td><td>Initial Press</td></tr>
    <tr id="code-2001"><td>2001</td><td>Dimmer / Wall Switch</td><td>Dim Up / Lower</td><td>Hold</td></tr>
    <tr id="code-2002"><td>2002</td><td>Dimmer / Wall Switch</td><td>Dim Up / Lower</td><td>Short Release</td></tr>
    <tr id="code-2003"><td>2003</td><td>Dimmer / Wall Switch</td><td>Dim Up / Lower</td><td>Long Release</td></tr>
    <tr id="code-3000"><td>3000</td><td>Dimmer Switch</td><td>Dim Down</td><td>Initial Press</td></tr>
    <tr id="code-3001"><td>3001</td><td>Dimmer Switch</td><td>Dim Down</td><td>Hold</td></tr>
    <tr id="code-3002"><td>3002</td><td>Dimmer Switch</td><td>Dim Down</td><td>Short Release</td></tr>
    <tr id="code-3003"><td>3003</td><td>Dimmer Switch</td><td>Dim Down</td><td>Long Release</td></tr>
    <tr id="code-4000"><td>4000</td><td>Dimmer Switch</td><td>Off</td><td>Initial Press</td></tr>
    <tr id="code-4001"><td>4001</td><td>Dimmer Switch</td><td>Off</td><td>Hold</td></tr>
    <tr id="code-4002"><td>4002</td><td>Dimmer Switch</td><td>Off</td><td>Short Release</td></tr>
    <tr id="code-4003"><td>4003</td><td>Dimmer Switch</td><td>Off</td><td>Long Release</td></tr>
    <tr id="code-16"><td>16</td><td>Tap Switch</td><td>Button 2</td><td>Press</td></tr>
    <tr id="code-17"><td>17</td><td>Tap Switch</td><td>Button 3</td><td>Press</td></tr>
    <tr id="code-18"><td>18</td><td>Tap Switch</td><td>Button 4</td><td>Press</td></tr>
    <tr id="code-34"><td>34</td><td>Tap Switch</td><td>Button 1</td><td>Press</td></tr>
  </tbody>
</table>
<p><a href="#top">Jump to Top</a></p>

<h2 class="summary-title" id="appendix-sensors">Appendix: System Sensor States</h2>
<p>This table lists the meanings of specific status values for system-generated sensors often used in rules for dynamic scenes.</p>
<table>
  <thead>
    <tr>
      <th>Sensor</th>
      <th>Status Value</th>
      <th>Meaning</th>
    </tr>
  </thead>
  <tbody>
    <tr><td>cycling</td><td>0</td><td>No dynamic color cycle is active.</td></tr>
    <tr><td>cycling</td><td>1</td><td>A dynamic color cycle is currently active.</td></tr>
    <tr><td>cycleState</td><td>0</td><td>Action: Stop the current dynamic scene.</td></tr>
    <tr><td>cycleState</td><td>1</td><td>Action: Start or activate the dynamic scene.</td></tr>
    <tr><td>cycleState</td><td>2</td><td>Action: Update the speed of the currently active scene.</td></tr>
    <tr><td>cycleState</td><td>3</td><td>Action: (Undocumented) Sets a specific, unknown state.</td></tr>
    <tr><td>cycleState</td><td>4</td><td>Action: Set the dynamic scene to a fixed, single color.</td></tr>
    <tr><td>cycleState</td><td>5</td><td>Action: Set the dynamic scene to random colors.</td></tr>
  </tbody>
</table>
<p><a href="#top">Jump to Top</a></p>
EOF

        # Close the HTML body
        echo "</div></body></html>" >> "$output_html"

        # --- SAVE THE RAW JSON DATA ---
        echo "$sorted_bridges_json" | jq '.' > "$output_json"
        
        echo
        echo "✅ Report generation complete!"
        echo "HTML saved as: '$output_html'"
        echo "Raw JSON data saved as: '$output_json'"
        
        # Report on the number of lights found
        echo
        echo "--- Light Count Summary ---"
        total_count=$(echo "$all_lights_json" | jq 'length')
        summary_data=$(echo "$all_lights_json" | jq 'group_by(.bridgeName) | map({bridge: .[0].bridgeName, count: length})')
        echo "$summary_data" | jq -r '.[] | "  - \(.bridge): \(.count) lights found."'
        
        group_summary=$(echo "$API_RESPONSE" | jq -r '
            .[] |
            "    \u001b[1m" + .bridge_name + " Groups:\u001b[0m" +
            (
                .groups | to_entries | sort_by(.value.name) |
                map("\n      - " + .value.name + ": " + (.value.lights | length | tostring) + " lights") | join("")
            )
        ')
        echo -e "$group_summary"
        
        echo "---------------------------"
        echo "  Total: $total_count lights across all bridges."
        
        
        # --- Console Summaries ---
        print_console_summaries "$all_lights_json" "$serials_json_content"


        # Ask to open the file
        read -p "Do you want to open the HTML report now? (Y/n): " open_choice
        if [[ "$open_choice" != "n" && "$open_choice" != "N" ]]; then
            open_command "$output_html"
        fi
    else
        echo
        echo "❗️ Report generation failed due to one or more errors." >&2
        echo "     Please check the error messages above for details." >&2
        echo "     Cleaning up incomplete report files..." >&2
        rm -f "$output_html" "$output_json"
    fi
}

# --- Main Script Execution ---

# Function to display the main menu
main_menu() {
    echo "What would you like to do?"
    echo "  1. Generate Hue Assets Report (HTML & JSON)"
    echo "  2. Create/Update Light Serial Number Mapping File"
    echo "  3. Exit"
    local menu_choice
    read -p "Enter number (1-3) [default: 1]: " menu_choice

    # Default to 1 if the user just presses Enter
    if [[ -z "$menu_choice" ]]; then
        menu_choice=1
    fi
    echo

    case $menu_choice in
        1)
            select_bridge
            fetch_data
            generate_report
            ;;
        2)
            generate_serials_file
            ;;
        3)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Please try again."
            main_menu
            ;;
    esac
}


# --- Script Entry Point ---
load_config
check_dependencies
main_menu

exit 0                                                             