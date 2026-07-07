#!/usr/bin/env bash
input="$(cat)"
out="$(printf '%s' "$input" | cat)"
printf '%q\n' "$out"
