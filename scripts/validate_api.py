#!/usr/bin/env python3
"""Validate the iOS client's API usage against a PinePods server's OpenAPI spec.

Usage:
    python3 scripts/validate_api.py <server-url>

Fetches /api/openapi.json from the server and
checks every endpoint the iOS APIClient calls: path, HTTP method, query params,
request body fields, and response fields. Endpoints the backend declares as
untyped (`serde_json::Value` responses) are skipped for response-field checks —
the spec cannot describe them — but they are verified against the backend
source in rust-api/src/handlers.
"""
import json
import sys
import urllib.request

if len(sys.argv) != 2:
    sys.exit("usage: validate_api.py <server-url>")
SERVER = sys.argv[1].rstrip("/")

spec_url = f"{SERVER}/api/openapi.json"
request = urllib.request.Request(spec_url, headers={"User-Agent": "PinePods-iOS-spec-check/1.0"})
try:
    with urllib.request.urlopen(request, timeout=30) as r:
        spec = json.load(r)
except Exception as e:
    print(f"Could not fetch spec from {spec_url}: {e}")
    sys.exit(2)

print(f"Validating against {spec_url} (PinePods API {spec['info']['version']})")

paths = spec["paths"]


def deref(ref):
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return ref
    node = spec
    for part in ref[2:].split("/"):
        node = node.get(part, {})
    return node


def schema_props(schema):
    if schema is None:
        return {}
    if "$ref" in schema:
        return schema_props(deref(schema["$ref"]))
    return schema.get("properties") or {}


def has_field(schema, field):
    return field in schema_props(schema)


# (path, method, query_params, required_body_fields, response_fields,
#  response_is_untyped) — untyped responses (serde_json::Value in the backend)
# are skipped for response-field checks.
CHECKS = [
    ("/api/pinepods_check", "get", set(), set(), {"pinepods_instance"}, False),
    ("/api/data/get_key", "get", set(), set(), {"retrieved_key", "mfa_required", "mfa_session_token", "user_id"}, False),
    ("/api/data/get_user", "get", set(), set(), {"status", "retrieved_id"}, False),
    ("/api/data/return_pods/{user_id}", "get", set(), set(), {"pods"}, False),
    ("/api/data/return_episodes/{user_id}", "get", {"limit", "offset"}, set(), {"episodes", "total"}, False),
    ("/api/data/podcast_episodes", "get", {"user_id", "podcast_id"}, set(), {"episodes", "total"}, False),
    ("/api/data/home_overview", "get", {"user_id"}, set(), {"recent_episodes", "in_progress_episodes", "queue_preview", "top_podcasts", "saved_count", "downloaded_count", "queue_count", "weekly_stats"}, True),
    ("/api/data/get_episode_metadata", "post", set(), {"episode_id", "user_id"}, {"episode"}, True),
    ("/api/data/record_listen_duration", "post", set(), {"episode_id", "user_id", "listen_duration", "is_youtube"}, set(), False),
    ("/api/data/mark_episode_completed", "post", set(), {"episode_id", "user_id"}, set(), False),
    ("/api/data/mark_episode_uncompleted", "post", set(), {"episode_id", "user_id"}, set(), False),
    ("/api/data/save_episode", "post", set(), {"episode_id", "user_id", "is_youtube"}, set(), False),
    ("/api/data/remove_saved_episode", "post", set(), {"episode_id", "user_id", "is_youtube"}, set(), False),
    ("/api/data/increment_played/{user_id}", "put", set(), set(), set(), False),
    ("/api/data/increment_listen_time/{user_id}", "put", set(), set(), set(), False),
    ("/api/data/get_play_episode_details", "post", set(), {"podcast_id", "user_id"}, {"playback_speed", "start_skip", "end_skip"}, False),
    ("/api/data/get_podcast_id_from_ep_id", "get", {"episode_id", "user_id", "is_youtube"}, set(), {"podcast_id"}, True),
    ("/api/data/download_podcast", "post", set(), {"episode_id", "user_id"}, set(), False),
    ("/api/data/delete_episode", "post", set(), {"episode_id", "user_id"}, set(), False),
    ("/api/data/saved_episode_list/{user_id}", "get", set(), set(), {"saved_episodes"}, False),
    ("/api/data/get_queued_episodes", "get", {"user_id"}, set(), {"data"}, False),
    ("/api/data/queue_pod", "post", set(), {"episode_id", "user_id", "is_youtube"}, set(), False),
    ("/api/data/remove_queued_pod", "post", set(), {"episode_id", "user_id", "is_youtube"}, set(), False),
    ("/api/data/reorder_queue", "post", {"user_id"}, {"episode_ids"}, set(), False),
    ("/api/data/clear_queue", "post", set(), {"user_id"}, set(), False),
    ("/api/data/user_history/{user_id}", "get", {"limit", "offset"}, set(), set(), False),
    ("/api/data/bulk_mark_episodes_completed", "post", set(), {"episode_ids", "user_id", "is_youtube"}, set(), False),
    ("/api/data/bulk_delete_downloaded_episodes", "post", set(), {"episode_ids", "user_id", "is_youtube"}, set(), False),
    ("/api/data/bulk_queue_episodes", "post", set(), {"episode_ids", "user_id", "is_youtube"}, set(), False),
    ("/api/data/download_episode_list", "get", {"user_id"}, set(), {"downloaded_episodes"}, False),
    ("/api/tasks/user/{user_id}", "get", set(), set(), set(), False),
    ("/api/data/stream/{episode_id}", "get", {"api_key", "user_id", "type"}, set(), set(), False),
    ("/api/data/verify_mfa_and_get_key", "post", set(), {"mfa_session_token", "mfa_code"}, {"retrieved_key"}, False),
]


def get_params(op):
    return {p["name"]: p.get("required", False) for p in op.get("parameters", [])}


failures = 0
for path, method, query, body, resp, untyped in CHECKS:
    op = paths.get(path, {}).get(method)
    if op is None:
        print(f"MISSING ENDPOINT: {method.upper()} {path}")
        failures += 1
        continue

    spec_params = get_params(op)
    for q in query:
        if q not in spec_params:
            print(f"{method.upper()} {path}: query param '{q}' not in spec (have: {sorted(spec_params)})")
            failures += 1

    if body:
        body_schema = (op.get("requestBody", {})
                       .get("content", {})
                       .get("application/json", {})
                       .get("schema"))
        if body_schema is None:
            print(f"{method.upper()} {path}: no application/json request body in spec")
            failures += 1
        else:
            for field in body:
                if not has_field(body_schema, field):
                    print(f"{method.upper()} {path}: body field '{field}' not in spec (have: {sorted(schema_props(body_schema))})")
                    failures += 1

    if resp and not untyped:
        resp_schema = ((op.get("responses", {}).get("200", {}) or {})
                       .get("content", {})
                       .get("application/json", {})
                       .get("schema"))
        if resp_schema is None:
            print(f"{method.upper()} {path}: no 200 application/json response in spec")
            failures += 1
        else:
            for field in resp:
                if not has_field(resp_schema, field):
                    print(f"{method.upper()} {path}: response field '{field}' not in spec (have: {sorted(schema_props(resp_schema))})")
                    failures += 1

if failures:
    print(f"\n{failures} mismatch(es)")
    sys.exit(1)
print(f"ALL {len(CHECKS)} ENDPOINTS PASS")
