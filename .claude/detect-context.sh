#!/bin/bash
# Detect which context-specific rules apply based on edited file path

FILE="$1"

# Determine context based on file glob patterns
if [[ "$FILE" =~ app/services/(bedrock|rag)/ ]] || [[ "$FILE" =~ /prompts/ ]]; then
  RULES="Bedrock & RAG Rules"
  GUIDANCE="Single-pass retrieval, minimize payloads, prefer metadata filtering, avoid chained LLM calls, never fabricate data"
elif [[ "$FILE" =~ app/.*\.rb$ ]]; then
  RULES="Rails Stack & Architecture"
  GUIDANCE="Thin controllers, service objects, prefer Rails-native, PORO services, avoid metaprogramming, flat app/services/"
elif [[ "$FILE" =~ app/views/.*\.erb$ ]] || [[ "$FILE" =~ app/javascript/.*\.js$ ]]; then
  RULES="Frontend Rules"
  GUIDANCE="Mobile-first, minimal typing, large tap targets, prefer Turbo/Stimulus, avoid SPA patterns"
else
  RULES="Performance Rules"
  GUIDANCE="Minimize Bedrock/API calls, minimize DB queries, avoid unnecessary async, direct execution paths"
fi

# Output JSON for hook to display
cat << EOF
{
  "systemMessage": "📋 $RULES applied: $GUIDANCE"
}
EOF
