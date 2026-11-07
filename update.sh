#!/bin/bash
set -e
cd "$(dirname "$(readlink -f "$0")")"
git pull --rebase origin main
