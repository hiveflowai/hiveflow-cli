#!/bin/bash
# Stub MCP server for tests/test_mcp_client.sh.
#
# Reads JSON-RPC 2.0 requests/notifications from stdin (one per line) and
# emits canned responses on stdout (also one per line). The dispatch table is
# intentionally tiny — just enough to exercise the P1.mcp-1 transport layer.
#
# Recognized methods:
#   initialize                  -> success result with protocolVersion + serverInfo
#   notifications/initialized   -> notification, no response (per spec)
#   ping                        -> empty result
#   echo                        -> result echoes the params verbatim
#   slow                        -> sleeps params.seconds (default 5) before reply
#   error_method                -> JSON-RPC error envelope (-32601 method not found)
#   bad_json_response           -> emits a malformed JSON line (for parse tests)
#   stray_notification          -> emits a notification BEFORE the response
#   tools/list                  -> two tools, paginated when env MCP_STUB_PAGINATE=1
#                                  (page 1 = [tool_a] + nextCursor=p2; page 2 = [tool_b]).
#                                  When env MCP_STUB_TOOLS_LIST_FAIL=1: error envelope.
#   tools/call                  -> dispatches by params.name:
#                                    error_tool     -> result.content + isError:true
#                                    server_error   -> JSON-RPC error envelope
#                                    *              -> echoes arguments as text content
#   shutdown                    -> emits result then exits the loop
#
# Anything else returns a JSON-RPC error envelope. The server flushes stdout
# after every write so the client's `read` doesn't stall waiting for buffers.

# Disable buffering on stdout if stdbuf is available; otherwise we rely on the
# fact that printf+newline is line-buffered by the OS for ttys/pipes.
exec 1>&1

while IFS= read -r line; do
    [ -z "$line" ] && continue

    method=$(printf '%s' "$line" | jq -r '.method // "unknown"' 2>/dev/null || echo "unknown")
    id_json=$(printf '%s' "$line" | jq -c '.id // null' 2>/dev/null || echo "null")

    case "$method" in
        initialize)
            jq -nc --argjson id "$id_json" \
                '{
                    jsonrpc: "2.0",
                    id: $id,
                    result: {
                        protocolVersion: "2024-11-05",
                        capabilities: { tools: {} },
                        serverInfo: { name: "stub", version: "0.0.1" }
                    }
                }'
            ;;
        notifications/initialized)
            : # Notifications get no response.
            ;;
        ping)
            jq -nc --argjson id "$id_json" '{jsonrpc:"2.0", id:$id, result:{}}'
            ;;
        echo)
            params=$(printf '%s' "$line" | jq -c '.params // null')
            jq -nc --argjson id "$id_json" --argjson params "$params" \
                '{jsonrpc:"2.0", id:$id, result:$params}'
            ;;
        slow)
            secs=$(printf '%s' "$line" | jq -r '.params.seconds // 5')
            sleep "$secs"
            jq -nc --argjson id "$id_json" '{jsonrpc:"2.0", id:$id, result:{slept:true}}'
            ;;
        error_method)
            jq -nc --argjson id "$id_json" \
                '{jsonrpc:"2.0", id:$id, error:{code:-32601, message:"Method not found"}}'
            ;;
        bad_json_response)
            printf 'this is not json\n'
            ;;
        stray_notification)
            jq -nc '{jsonrpc:"2.0", method:"server/heartbeat", params:{tick:1}}'
            jq -nc --argjson id "$id_json" '{jsonrpc:"2.0", id:$id, result:{after_stray:true}}'
            ;;
        tools/list)
            if [ "${MCP_STUB_TOOLS_LIST_FAIL:-0}" = "1" ]; then
                jq -nc --argjson id "$id_json" \
                    '{jsonrpc:"2.0", id:$id, error:{code:-32000, message:"tools listing disabled"}}'
            elif [ "${MCP_STUB_PAGINATE:-0}" = "1" ]; then
                cursor=$(printf '%s' "$line" | jq -r '.params.cursor // ""')
                if [ "$cursor" = "p2" ]; then
                    jq -nc --argjson id "$id_json" \
                        '{jsonrpc:"2.0", id:$id, result:{
                            tools:[{
                                name:"tool_b",
                                description:"second tool",
                                inputSchema:{type:"object", properties:{q:{type:"string"}}}
                            }]
                        }}'
                else
                    jq -nc --argjson id "$id_json" \
                        '{jsonrpc:"2.0", id:$id, result:{
                            tools:[{
                                name:"tool_a",
                                description:"first tool",
                                inputSchema:{type:"object", properties:{x:{type:"integer"}}}
                            }],
                            nextCursor:"p2"
                        }}'
                fi
            else
                jq -nc --argjson id "$id_json" \
                    '{jsonrpc:"2.0", id:$id, result:{
                        tools:[
                            {
                                name:"tool_a",
                                description:"first tool",
                                inputSchema:{type:"object", properties:{x:{type:"integer"}}}
                            },
                            {
                                name:"tool_b",
                                description:"second tool",
                                inputSchema:{type:"object", properties:{q:{type:"string"}}}
                            }
                        ]
                    }}'
            fi
            ;;
        tools/call)
            tool_name=$(printf '%s' "$line" | jq -r '.params.name // ""')
            args=$(printf '%s' "$line" | jq -c '.params.arguments // {}')
            case "$tool_name" in
                error_tool)
                    jq -nc --argjson id "$id_json" --argjson args "$args" \
                        '{jsonrpc:"2.0", id:$id, result:{
                            content:[{type:"text", text:"tool reported failure"}],
                            isError:true
                        }}'
                    ;;
                server_error)
                    jq -nc --argjson id "$id_json" \
                        '{jsonrpc:"2.0", id:$id, error:{code:-32602, message:"Invalid params"}}'
                    ;;
                *)
                    jq -nc --argjson id "$id_json" --arg n "$tool_name" --argjson args "$args" \
                        '{jsonrpc:"2.0", id:$id, result:{
                            content:[{type:"text", text:("called " + $n + " with " + ($args | tostring))}],
                            isError:false
                        }}'
                    ;;
            esac
            ;;
        shutdown)
            jq -nc --argjson id "$id_json" '{jsonrpc:"2.0", id:$id, result:{bye:true}}'
            break
            ;;
        unknown|*)
            jq -nc --argjson id "$id_json" \
                '{jsonrpc:"2.0", id:$id, error:{code:-32601, message:"Method not found"}}'
            ;;
    esac
done

exit 0
