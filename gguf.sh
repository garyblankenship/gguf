#!/bin/bash

# 🦙 Welcome to the GGUF (Groovy GGUF Utility Functions) script! 🚀
#
# Prerequisites (because even llamas need tools):
# - llama-server command (macOS: brew install llama.cpp)
# - huggingface-cli command (macOS: brew install huggingface-cli)
# - sqlite3 (usually pre-installed on macOS, like a built-in llama pouch)
# - jq (macOS: brew install jq) - because parsing JSON without jq is like trying to shear a llama with scissors!
#
# This script is your friendly neighborhood llama wrangler! 🤠
# It manages and interacts with large language models using llama.cpp,
# providing a whole petting zoo of functionality:
# - Download models (like adopting new llamas)
# - Run models (let your llamas roam free in the digital pasture)
# - Chat with models (have a heart-to-heart with your favorite llama)
# - Manage a local database of model information (keep track of your llama herd)
#
# So saddle up, partner! Let's wrangle some AI llamas! 🤠🦙

# Configuration Variables
MODELS_DIR="$HOME/.cache/gguf/models/"
LLAMA_SERVER="/opt/homebrew/bin/llama-server"
LLAMA_CLI="/opt/homebrew/bin/llama-cli"
DB_PATH="$HOME/.cache/gguf/gguf.db"
DEFAULT_PORT=1979

# Model parameters
TEMPERATURE=0.7
TOP_K=40
TOP_P=0.5
N_PREDICT=256

# Helper Functions
trim_blank_lines() {
    sed '/^[[:space:]]*$/d'
}

ensure_server_running() {
    local slug="$1"
    local model_path
    model_path=$(get_model_path "$slug") || return 1
    update_last_used "$slug"

    if ! pgrep -f "llama-server.*$model_path" > /dev/null; then
        log_info "Starting server for model $slug..."
        local log_file="/tmp/llama_server_${slug}.log"
        nohup "$LLAMA_SERVER" -m "$model_path" --port "$DEFAULT_PORT" > "$log_file" 2>&1 &
        local server_pid=$!
        log_info "Server started with PID $server_pid. Logs: $log_file"

        wait_for_server
    else
        log_info "Server for model $slug is already running."
    fi
}

wait_for_server() {
    local wait_time=0
    local max_wait_time=300  # 5 minutes
    while ! nc -z localhost "$DEFAULT_PORT"; do
        if [ $wait_time -ge $max_wait_time ]; then
            log_error "Server failed to start within $max_wait_time seconds. Check logs: $log_file"
            return 1
        fi
        if (( wait_time % 10 == 0 )); then
            echo -n "."
        fi
        sleep 1
        ((wait_time++))
    done
    echo ""  # New line after dots
    log_info "Server is ready after $wait_time seconds."
}

api_request() {
    local method="$1"   # GET or POST
    local endpoint="$2" # API endpoint
    local data="$3"     # JSON data for POST requests

    curl -s -w "\n%{http_code}" -X "$method" "http://localhost:$DEFAULT_PORT/$endpoint" \
        -H "Content-Type: application/json" ${data:+-d "$data"}
}

handle_response() {
    local response="$1"
    local success_action="$2"  # Command to execute on success
    local failure_action="$3"  # Command to execute on failure

    local status_code
    status_code=$(echo "$response" | tail -n1)
    local content
    content=$(echo "$response" | sed '$d')

    if [ "$status_code" -eq 200 ]; then
        eval "$success_action"
    else
        eval "$failure_action"
    fi
}

# Initialize the database if it doesn't exist
init_database() {
    sqlite3 "$DB_PATH" <<EOF
    CREATE TABLE IF NOT EXISTS models (
        id INTEGER PRIMARY KEY,
        slug TEXT UNIQUE,
        model_id TEXT,
        file_name TEXT,
        file_path TEXT,
        file_size TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        last_used DATETIME
    );
EOF
}

# Utility Functions
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

validate_model_id() {
    local model_id="$1"
    if [[ ! "$model_id" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+$ ]]; then
        log_error "Invalid Hugging Face model ID. It should be in the form 'author/model-name'."
        return 1
    fi
    return 0
}

generate_slug() {
    local model_path="$1"
    echo "$model_path" | sed 's|.*/||; s|/|-|g; s|[[:upper:]]|\\L&|g; s|[^a-z0-9]|-|g; s|--*|-|g; s|^-||; s|-$||'
}

add_model_to_db() {
    local slug="$1" model_id="$2" file_name="$3" file_path="$4" file_size="$5"
    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO models (slug, model_id, file_name, file_path, file_size)
    VALUES ('$slug', '$model_id', '$file_name', '$file_path', '$file_size');"
}

get_model_path() {
    local slug="$1"
    local result
    result=$(sqlite3 "$DB_PATH" "SELECT file_path FROM models WHERE slug='$slug';")
    if [ -z "$result" ]; then
        log_error "Model with slug '$slug' not found in the database."
        list_models >&2
        return 1
    fi
    echo "$result"
}

update_last_used() {
    local slug="$1"
    sqlite3 "$DB_PATH" "UPDATE models SET last_used=CURRENT_TIMESTAMP WHERE slug='$slug';"
}

remove_model_from_db() {
    local slug="$1"
    sqlite3 "$DB_PATH" "DELETE FROM models WHERE slug='$slug';"
}

list_models() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf ls"
        echo "List all models in the database."
        return 0
    fi
    (
        echo "SLUG|MODEL|SIZE|LAST USED"
        sqlite3 -separator "|" "$DB_PATH" "
        SELECT 
            slug, 
            file_name,
            file_size,
            COALESCE(datetime(last_used), 'Never') as last_used 
        FROM models 
        ORDER BY last_used DESC, created_at DESC;"
    ) | column -t -s '|'
}

# Model Management Functions
pull_model() {
    local model_id="$1"
    if [ "$model_id" == "--help" ]; then
        echo "Usage: gguf pull <model_id>"
        echo "Download a new model from Hugging Face."
        echo
        echo "Arguments:"
        echo "  <model_id>  The Hugging Face model ID (e.g., 'author/model-name')"
        return 0
    fi
    if ! validate_model_id "$model_id"; then return 1; fi

    local model_dir="$MODELS_DIR/$model_id"
    log_info "Checking for existing files in $model_dir..."

    if [ -d "$model_dir" ] && find "$model_dir" -name "*.gguf" -print -quit | grep -q .; then
        log_warn "Model already exists in $model_dir. Remove existing files to re-download."
        return 0
    fi

    log_info "Downloading Q4_K_M.gguf file for model $model_id..."
    huggingface-cli download "$model_id" --include "*Q4_K_M.gguf" --local-dir "$model_dir"

    local downloaded_file
    downloaded_file=$(find "$model_dir" -name "*Q4_K_M.gguf")

    if [ -n "$downloaded_file" ]; then
        local file_size
        file_size=$(du -h "$downloaded_file" | cut -f1)
        local slug
        slug=$(generate_slug "$model_id")
        local file_name
        file_name=$(basename "$downloaded_file")
        add_model_to_db "$slug" "$model_id" "$file_name" "$downloaded_file" "$file_size"
        log_info "Model added to database with slug: $slug"
        echo "To use this model, run: gguf chat $slug"
    else
        log_error "No Q4_K_M.gguf file found after download attempt."
    fi
}

remove_model() {
    local slug="$1"
    if [ "$slug" == "--help" ]; then
        echo "Usage: gguf rm <slug>"
        echo "Remove a model from the filesystem and database."
        echo
        echo "Arguments:"
        echo "  <slug>  The slug of the model to remove"
        return 0
    fi
    local model_path
    model_path=$(get_model_path "$slug") || return 1

    rm -f "$model_path"
    remove_model_from_db "$slug"
    log_info "Model '$slug' removed from filesystem and database."
}

import_existing_models() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf import [--help]"
        echo "Import existing models from the filesystem into the database."
        echo
        echo "Description:"
        echo "  This command scans the MODELS_DIR ($MODELS_DIR) for .gguf files"
        echo "  and adds them to the database if they're not already present."
        echo "  It's useful for synchronizing the database with manually added models"
        echo "  or after moving/copying models to the MODELS_DIR."
        echo
        echo "Process:"
        echo "  1. Scans MODELS_DIR for .gguf files"
        echo "  2. For each file, generates a slug based on the file path"
        echo "  3. Checks if the model is already in the database"
        echo "  4. If not present, adds the model to the database with details like:"
        echo "     - Slug (for easy reference)"
        echo "     - Model ID (derived from file path)"
        echo "     - File name"
        echo "     - File path"
        echo "     - File size"
        echo
        echo "Options:"
        echo "  --help  Show this help message"
        return 0
    fi

    log_info "Scanning for existing models in $MODELS_DIR..."
    find "$MODELS_DIR" -type f -name "*.gguf" | while read -r file_path; do
        local file_name model_id slug file_size
        file_name=$(basename "$file_path")
        model_id=$(echo "$file_path" | sed "s|$MODELS_DIR/||")
        slug=$(generate_slug "$model_id")
        file_size=$(du -h "$file_path" | cut -f1)
        local existing
        existing=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM models WHERE file_path='$file_path';")
        if [ "$existing" -eq 0 ]; then
            add_model_to_db "$slug" "$model_id" "$file_name" "$file_path" "$file_size"
            log_info "Imported model: $slug"
        else
            log_warn "Model already in database: $slug"
        fi
    done
    log_info "Import completed."
}

reset_db() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf reset"
        echo "Reset the database and re-import existing models."
        return 0
    fi
    log_warn "Resetting the database..."
    rm -f "$DB_PATH"
    init_database
    import_existing_models
    log_info "Database reset and import complete."
}

alias_model() {
    local old_slug="$1" new_slug="$2"
    if [ "$old_slug" == "--help" ]; then
        echo "Usage: gguf alias <old_slug> <new_slug>"
        echo "Create an alias for a model."
        echo
        echo "Arguments:"
        echo "  <old_slug>  The current slug of the model"
        echo "  <new_slug>  The new slug to assign to the model"
        return 0
    fi
    if [ -z "$old_slug" ] || [ -z "$new_slug" ]; then
        echo "Usage: gguf alias <old_slug> <new_slug>"
        return 1
    fi

    local exists new_exists
    exists=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM models WHERE slug='$old_slug';")
    new_exists=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM models WHERE slug='$new_slug';")

    if [ "$exists" -eq 0 ]; then
        log_error "Model with slug '$old_slug' not found."
        return 1
    elif [ "$new_exists" -ne 0 ]; then
        log_error "Model with slug '$new_slug' already exists."
        return 1
    fi

    sqlite3 "$DB_PATH" "UPDATE models SET slug='$new_slug' WHERE slug='$old_slug';"
    log_info "Model '$old_slug' aliased to '$new_slug'."
}

# Server Management Functions
run_model() {
    local slug="$1"
    shift
    if [ "$slug" == "--help" ]; then
        echo "Usage: gguf run <slug> [text]"
        echo "Run a model server and optionally complete text."
        echo
        echo "Arguments:"
        echo "  <slug>  The slug of the model to run"
        echo "  [text]  Optional text for completion"
        return 0
    fi

    ensure_server_running "$slug" || return 1

    if [ $# -gt 0 ]; then
        local prompt="$*"
        log_info "Completing text: $prompt"
        
        local term_width=$(tput cols)
        printf '%*s\n' "$term_width" | tr ' ' '─'
        
        local data
        data=$(jq -n --arg p "$prompt" --arg n "$N_PREDICT" --arg t "$TEMPERATURE" --arg k "$TOP_K" --arg tp "$TOP_P" \
            '{prompt: $p, n_predict: ($n|tonumber), temperature: ($t|tonumber), top_k: ($k|tonumber), top_p: ($tp|tonumber)}')

        local response
        response=$(api_request POST "completion" "$data")

        handle_response "$response" \
            "echo \"\$content\" | jq -r '.content' | trim_blank_lines" \
            "log_error \"Failed to complete text. Status code: \$status_code\"; echo \"\$content\""

        return 0
    fi
}

kill_model() {
    local slug="$1"
    if [ "$slug" == "--help" ]; then
        echo "Usage: gguf kill <slug|all>"
        echo "Kill the server running the specified model or all servers."
        echo
        echo "Arguments:"
        echo "  <slug>  The slug of the model to kill, or 'all' to kill all servers"
        echo
        echo "Use 'gguf ps' to see running models."
        return 0
    fi
    if [ -z "$slug" ]; then
        log_error "No model slug provided. Usage: gguf kill <slug>"
        log_info "Use 'gguf ps' to see running models."
        return 1
    fi

    local pids
    pids=$(ps aux | grep "[l]lama-server.*$slug" | awk '{print $2}')
    if [ -z "$pids" ]; then
        log_warn "No running server found for model '$slug'."
        return 1
    fi

    for pid in $pids; do
        kill "$pid"
        if [ $? -eq 0 ]; then
            log_info "Server for model '$slug' (PID: $pid) terminated."
        else
            log_error "Failed to terminate server for model '$slug' (PID: $pid)."
        fi
    done
}

kill_all_servers() {
    local pids
    pids=$(pgrep -f "llama-server")
    if [ -z "$pids" ]; then
        log_warn "No running llama-server processes found."
        return 0
    fi

    log_info "Killing all llama-server processes..."
    kill $pids
    sleep 2

    # Force kill if any remain
    pids=$(pgrep -f "llama-server")
    if [ -n "$pids" ]; then
        kill -9 $pids
    fi
    log_info "All llama-server processes terminated."
}

show_processes() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf ps"
        echo "Show running llama-server processes."
        return 0
    fi
    (
        echo "PID|SLUG|MODEL"
        ps aux | grep "[l]lama-server" | while read -r line; do
            pid=$(echo "$line" | awk '{print $2}')
            cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i}')
            model_file=$(echo "$cmd" | awk -F '-m ' '{print $2}' | awk '{print $1}' | xargs basename)
            if [ -n "$model_file" ]; then
                model=${model_file%.gguf}
                slug=$(sqlite3 "$DB_PATH" "SELECT slug FROM models WHERE file_name='$model_file' LIMIT 1;")
                if [ -z "$slug" ]; then
                    slug="unknown"
                fi
            else
                model="Unknown"
                slug="unknown"
            fi
            echo "$pid|$slug|$model"
        done
    ) | column -t -s '|'
}

# Model Operations Functions
print_help() {
    local command="$1"
    local description="$2"
    local args="$3"
    echo "Usage: gguf $command $args"
    echo "$description"
    echo
    echo "Arguments:"
    echo "$args"
}

run_model_operation() {
    local slug="$1"
    local operation="$2"
    local data="$3"
    shift 3

    ensure_server_running "$slug" || return 1
    sleep 2

    local response
    response=$(api_request POST "$operation" "$data")

    handle_response "$response" \
        "echo \"\$content\" | jq '.' | trim_blank_lines" \
        "log_error \"Failed to perform $operation. Status code: \$status_code\"; echo \"\$content\""
}

chat_model() {
    local slug="$1"
    shift
    if [ "$slug" == "--help" ]; then
        print_help "chat" "Start an interactive chat session with the specified model." "<slug>  The slug of the model to chat with"
        return 0
    fi
    run_model "$slug" || return 1

    log_info "Starting chat session. Type 'exit' to end."
    declare -a messages=()

    while true; do
        read -rp "User: " user_input
        [[ "$user_input" == "exit" ]] && break

        messages+=("{\"role\": \"user\", \"content\": \"$user_input\"}")
        local messages_json
        messages_json=$(IFS=,; echo "${messages[*]}")

        local response
        response=$(api_request POST "v1/chat/completions" "{
            \"messages\": [$messages_json],
            \"temperature\": 0.7,
            \"max_tokens\": 1024
        }")

        handle_response "$response" \
            "assistant_message=\$(echo \"\$content\" | jq -r '.choices[0].message.content'); \
             echo \"Assistant: \$assistant_message\"; \
             messages+=(\"{\\\"role\\\": \\\"assistant\\\", \\\"content\\\": \\\"\$assistant_message\\\"}\")" \
            "log_error \"Failed to get chat response. Status code: \$status_code\"; echo \"\$content\"; break"
    done

    log_info "Chat session ended."
}

complete_model() {
    local slug="$1"
    shift
    if [ "$slug" == "--help" ]; then
        print_help "complete" "Generate text completion for the given prompt." "<slug>    The slug of the model to use
  <prompt>  The prompt for text completion"
        return 0
    fi
    local prompt="$*"

    local data
    data=$(jq -n --arg p "$prompt" --arg n "$N_PREDICT" --arg t "$TEMPERATURE" --arg k "$TOP_K" --arg tp "$TOP_P" \
        '{prompt: $p, n_predict: ($n|tonumber), temperature: ($t|tonumber), top_k: ($k|tonumber), top_p: ($tp|tonumber)}')

    run_model_operation "$slug" "completion" "$data"
}

embed_model() {
    local slug="$1" text="$2"
    if [ "$slug" == "--help" ]; then
        print_help "embed" "Generate embeddings for the given text using the specified model." "<model_slug>  The slug of the model to use for embedding
  <text>        The text to generate embeddings for"
        echo
        echo "Example:"
        echo "  gguf embed chat \"Hello, world!\""
        return 0
    fi

    run_model_operation "$slug" "embedding" "{\"content\": \"$text\"}"
}

tokenize_text() {
    local slug="$1" text="$2"
    if [ "$slug" == "--help" ] || [ "$text" == "--help" ]; then
        print_help "tokenize" "Tokenize the given text using the specified model." "<model_slug>  The slug of the model to use for tokenization
  <text>        The text to tokenize"
        return 0
    fi

    run_model_operation "$slug" "tokenize" "{\"content\": \"$text\"}"
}

detokenize_text() {
    local slug="$1" tokens="$2"
    if [ "$slug" == "--help" ]; then
        print_help "detokenize" "Detokenize the given tokens using the specified model." "<model_slug>  The slug of the model to use for detokenization
  <tokens>      The tokens to detokenize (as a JSON array)"
        return 0
    fi

    run_model_operation "$slug" "detokenize" "{\"tokens\": $tokens}"
}

# Server Information Functions
check_health() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf health"
        echo "Check the health status of the running server."
        return 0
    fi
    local response status_code body
    response=$(curl -s -w "\n%{http_code}" http://localhost:$DEFAULT_PORT/health)
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$status_code" -eq 200 ]; then
        log_info "Server is healthy."
        echo "$body" | jq '.'
    else
        log_error "Server not healthy (Status code: $status_code)"
        echo "$body"
    fi
}

get_recent_models() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf recent"
        echo "Get the 20 most recent GGUF models from Hugging Face."
        return 0
    fi
    curl -s -X GET "https://huggingface.co/api/models?filter=gguf&sort=lastModified" | 
    jq -r '.[] | select(.tags | contains(["gguf"])) | 
           [.modelId, .lastModified, (.likes // 0), (.downloads // 0)] | 
           @tsv' | 
    head -n 20 |
    (echo -e "MODEL ID\tLAST MODIFIED\tLIKES\tDOWNLOADS" && cat) | 
    column -t -s $'\t'
}

get_trending_models() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf trending"
        echo "Get the top 20 trending GGUF models from Hugging Face by a combination of likes and downloads, with likes as the primary sort criteria."
        return 0
    fi
    curl -s -X GET "https://huggingface.co/api/models?filter=gguf&sort=lastModified" | 
    jq -r '.[] | select(.tags | contains(["gguf"])) | 
           [.modelId, .lastModified, (.likes // 0), (.downloads // 0)] | 
           @tsv' | 
    sort -nr -k3,4 | 
    head -n 20 |
    (echo -e "MODEL ID\tLAST MODIFIED\tLIKES\tDOWNLOADS" && cat) | 
    column -t -s $'\t'
}

get_server_props() {
    if [ "$1" == "--help" ]; then
        echo "Usage: gguf props"
        echo "Get the properties of the running server."
        return 0
    fi
    curl -s http://localhost:$DEFAULT_PORT/props | jq '.'
}

# Usage Information
print_usage() {
    local NC='\033[0m'
    local CYAN='\033[0;36m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[0;33m'
    local MAGENTA='\033[0;35m'
    local DARK_GRAY='\033[0;90m'

    echo -e "${CYAN}Usage:${NC} gguf ${GREEN}<command>${NC} [options]"
    echo
    echo -e "${YELLOW}Model Management:${NC}"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "pull <model_id>" "......................." "Download a new model"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "rm <slug>" "......................." "Remove a model"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "ls" "......................." "List all models"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "alias <old> <new>" "......................." "Create an alias for a model"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "import" "......................." "Import existing models"
    echo
    echo -e "${YELLOW}Model Operations:${NC}"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "run <slug> [text]" "......................." "Run a model server and optionally complete text"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "chat <slug>" "......................." "Start a chat session"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "embed <slug> <text>" "......................." "Generate embeddings"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "tokenize <slug> <text>" "......................." "Tokenize text"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "detokenize <slug> <tokens>" "......................." "Detokenize text"
    echo
    echo -e "${YELLOW}Server Information:${NC}"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "health" "......................." "Check server health"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "props" "......................." "Get server properties"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "ps" "......................." "Show running processes"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "kill <slug|all>" "......................." "Kill a model server"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "reset" "......................." "Reset the database"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "recent" "......................." "Get most recent GGUF models"
    printf "  ${GREEN}%-26s${NC} ${DARK_GRAY}%s${NC} %s\n" "trending" "......................." "Get trending GGUF models"
    echo
    echo -e "${MAGENTA}For more information, use:${NC} gguf ${GREEN}<command> --help${NC}"
}

# Main Script Logic
main() {
    # Initialize the database
    init_database

    case "$1" in
        pull)
            shift
            pull_model "$@"
            ;;
        rm)
            shift
            remove_model "$@"
            ;;
        ls)
            list_models
            ;;
        alias)
            shift
            alias_model "$@"
            ;;
        import)
            shift
            import_existing_models "$@"
            ;;
        reset)
            reset_db
            ;;
        run)
            shift
            run_model "$@"
            ;;
        chat)
            shift
            chat_model "$@"
            ;;
        embed)
            shift
            embed_model "$@"
            ;;
        tokenize)
            shift
            tokenize_text "$@"
            ;;
        detokenize)
            shift
            detokenize_text "$@"
            ;;
        health)
            check_health
            ;;
        props)
            get_server_props
            ;;
        ps)
            show_processes
            ;;
        kill)
            shift
            if [ "$1" = "all" ]; then
                kill_all_servers
            else
                kill_model "$@"
            fi
            ;;
        recent)
            get_recent_models "$@"
            ;;
        trending)
            get_trending_models "$@"
            ;;
        *)
            print_usage
            ;;
    esac
}

main "$@"

