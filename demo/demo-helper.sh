#!/bin/bash
# demo-helper.sh - Formatting helpers for claude-warden demo video
# Provides colored headers, section breaks, and mock data generators

set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$DEMO_DIR/../hooks" && pwd)"

# Print a scene header
scene() {
    printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n\n" "$*"
}

# Print a description line
desc() {
    printf "${DIM}# %s${RESET}\n" "$*"
}

# Print a pass/allow result
pass() {
    printf "${GREEN}ALLOWED${RESET}: %s\n" "$*"
}

# Print a blocked result
blocked() {
    printf "${RED}BLOCKED${RESET}: %s\n" "$*"
}

# Run a hook with a mock input and display the result
run_hook() {
    local hook="$1"
    local input_file="$2"
    local label="${3:-}"

    if [[ -n "$label" ]]; then
        printf "${YELLOW}> ${RESET}%s\n" "$label"
    fi

    local exit_code=0
    local stdout stderr
    stderr=$(mktemp)
    stdout=$(cat "$input_file" | "$HOOKS_DIR/$hook" 2>"$stderr") || exit_code=$?

    if [[ $exit_code -eq 2 ]]; then
        printf "${RED}BLOCKED${RESET} (exit 2): %s\n" "$(cat "$stderr")"
    elif [[ $exit_code -eq 0 ]]; then
        if [[ -n "$stdout" ]]; then
            # Check if it's JSON with modifyOutput or suppressOutput
            if echo "$stdout" | jq -e '.modifyOutput' &>/dev/null; then
                printf "${GREEN}MODIFIED${RESET}: output compressed/truncated\n"
                echo "$stdout" | jq -r '.modifyOutput' | head -20
            elif echo "$stdout" | jq -e '.suppressOutput' &>/dev/null; then
                printf "${GREEN}ALLOWED${RESET} (output suppressed)\n"
            else
                printf "${GREEN}ALLOWED${RESET}\n"
                echo "$stdout"
            fi
        else
            printf "${GREEN}ALLOWED${RESET}\n"
        fi
    else
        printf "${YELLOW}EXIT %d${RESET}: %s\n" "$exit_code" "$(cat "$stderr")"
    fi
    rm -f "$stderr"
    echo ""
}

# Generate a large output JSON for post-tool-use testing
generate_large_output() {
    local size_kb="${1:-30}"
    local line="[2025-01-15T10:23:45Z] INFO: Processing request handler pipeline stage completed successfully with status=200 method=GET path=/api/v1/users duration=45ms"
    local tmpfile json_file
    tmpfile=$(mktemp)
    json_file=$(mktemp)
    local target_bytes=$((size_kb * 1024))
    local current=0
    while (( current < target_bytes )); do
        echo "$line" >> "$tmpfile"
        current=$(( current + ${#line} + 1 ))
    done
    # Build JSON with text properly escaped via jq
    local escaped_text
    escaped_text=$(jq -Rs '.' < "$tmpfile")
    cat > "$json_file" <<EOJSON
{"tool_name":"Bash","tool_input":{"command":"cat /var/log/app.log"},"session_id":"demo-session","tool_response":{"content":[{"text":${escaped_text}}]}}
EOJSON
    cat "$json_file"
    rm -f "$tmpfile" "$json_file"
}

# Generate a synthetic source file for read-compress testing
generate_source_file() {
    local lines="${1:-200}"
    cat <<'PYEOF'
import os
import sys
import json
import logging
from pathlib import Path
from typing import Optional, Dict, List, Any, Tuple
from dataclasses import dataclass, field
from collections import defaultdict
from functools import lru_cache

logger = logging.getLogger(__name__)

# Configuration constants
DEFAULT_TIMEOUT = 30
MAX_RETRIES = 3
BUFFER_SIZE = 8192

@dataclass
class ServerConfig:
    host: str = "localhost"
    port: int = 8080
    debug: bool = False
    workers: int = 4
    timeout: int = DEFAULT_TIMEOUT
    max_connections: int = 100

@dataclass
class DatabaseConfig:
    url: str = "sqlite:///app.db"
    pool_size: int = 5
    echo: bool = False

class ConnectionPool:
    """Manages database connection pooling."""

    def __init__(self, config: DatabaseConfig):
        self._config = config
        self._pool: List[Any] = []
        self._active = 0
        self._lock = None

    def acquire(self) -> Any:
        """Acquire a connection from the pool."""
        if self._pool:
            conn = self._pool.pop()
            self._active += 1
            return conn
        if self._active < self._config.pool_size:
            conn = self._create_connection()
            self._active += 1
            return conn
        raise RuntimeError("Connection pool exhausted")

    def release(self, conn: Any) -> None:
        """Release a connection back to the pool."""
        self._active -= 1
        if len(self._pool) < self._config.pool_size:
            self._pool.append(conn)

    def _create_connection(self) -> Any:
        """Create a new database connection."""
        return None  # Placeholder

class RequestHandler:
    """Base request handler with middleware support."""

    def __init__(self, config: ServerConfig):
        self.config = config
        self._middleware: List[Any] = []
        self._routes: Dict[str, Any] = {}

    def add_middleware(self, middleware: Any) -> None:
        """Add middleware to the request pipeline."""
        self._middleware.append(middleware)

    def route(self, path: str, method: str = "GET"):
        """Decorator to register a route handler."""
        def decorator(func):
            key = f"{method}:{path}"
            self._routes[key] = func
            return func
        return decorator

    async def handle(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Process an incoming request through middleware and route handler."""
        for mw in self._middleware:
            request = await mw.process(request)
        method = request.get("method", "GET")
        path = request.get("path", "/")
        key = f"{method}:{path}"
        handler = self._routes.get(key)
        if handler is None:
            return {"status": 404, "body": "Not Found"}
        return await handler(request)

class CacheManager:
    """In-memory cache with TTL support."""

    def __init__(self, max_size: int = 1000, default_ttl: int = 300):
        self._cache: Dict[str, Tuple[Any, float]] = {}
        self._max_size = max_size
        self._default_ttl = default_ttl
        self._hits = 0
        self._misses = 0

    def get(self, key: str) -> Optional[Any]:
        """Get a value from cache."""
        entry = self._cache.get(key)
        if entry is None:
            self._misses += 1
            return None
        value, expiry = entry
        import time
        if time.time() > expiry:
            del self._cache[key]
            self._misses += 1
            return None
        self._hits += 1
        return value

    def set(self, key: str, value: Any, ttl: Optional[int] = None) -> None:
        """Set a value in cache with optional TTL."""
        import time
        if len(self._cache) >= self._max_size:
            self._evict()
        expiry = time.time() + (ttl or self._default_ttl)
        self._cache[key] = (value, expiry)

    def _evict(self) -> None:
        """Evict expired or oldest entries."""
        import time
        now = time.time()
        expired = [k for k, (_, exp) in self._cache.items() if now > exp]
        for k in expired:
            del self._cache[k]

    @property
    def stats(self) -> Dict[str, int]:
        """Return cache hit/miss statistics."""
        total = self._hits + self._misses
        return {
            "hits": self._hits,
            "misses": self._misses,
            "hit_rate": round(self._hits / total * 100, 1) if total > 0 else 0,
            "size": len(self._cache),
        }

class EventBus:
    """Simple publish-subscribe event bus."""

    def __init__(self):
        self._subscribers: Dict[str, List[Any]] = defaultdict(list)

    def subscribe(self, event: str, handler: Any) -> None:
        """Subscribe to an event."""
        self._subscribers[event].append(handler)

    def unsubscribe(self, event: str, handler: Any) -> None:
        """Unsubscribe from an event."""
        self._subscribers[event].remove(handler)

    async def publish(self, event: str, data: Any = None) -> None:
        """Publish an event to all subscribers."""
        for handler in self._subscribers.get(event, []):
            await handler(data)

@lru_cache(maxsize=128)
def parse_config(path: str) -> Dict[str, Any]:
    """Parse a JSON configuration file with caching."""
    with open(path) as f:
        return json.load(f)

def setup_logging(level: str = "INFO", format_string: Optional[str] = None) -> None:
    """Configure application logging."""
    fmt = format_string or "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    logging.basicConfig(level=getattr(logging, level.upper()), format=fmt)

def validate_config(config: Dict[str, Any]) -> List[str]:
    """Validate configuration and return list of errors."""
    errors = []
    if "host" not in config:
        errors.append("Missing required field: host")
    if "port" in config:
        port = config["port"]
        if not isinstance(port, int) or port < 1 or port > 65535:
            errors.append(f"Invalid port: {port}")
    return errors

def create_app(config_path: Optional[str] = None) -> RequestHandler:
    """Application factory - create and configure the app."""
    if config_path:
        raw_config = parse_config(config_path)
        errors = validate_config(raw_config)
        if errors:
            raise ValueError(f"Config errors: {errors}")
        config = ServerConfig(**{k: v for k, v in raw_config.items() if hasattr(ServerConfig, k)})
    else:
        config = ServerConfig()

    app = RequestHandler(config)
    setup_logging()
    logger.info("Application created with config: %s", config)
    return app

if __name__ == "__main__":
    app = create_app(sys.argv[1] if len(sys.argv) > 1 else None)
    print(f"Server ready on {app.config.host}:{app.config.port}")
PYEOF
}

# Build a read-compress input JSON from a source file
build_read_compress_input() {
    local content
    content=$(generate_source_file)
    jq -n \
        --arg text "$content" \
        --arg tp "/tmp/subagent-demo/transcript.jsonl" \
        '{
            tool_name: "Read",
            transcript_path: $tp,
            tool_response: { content: [{ text: $text }] }
        }'
}

"$@"
