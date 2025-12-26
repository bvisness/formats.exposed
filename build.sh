#!/bin/bash

set -euo pipefail

odin build parsers/png.odin -file -target:js_wasm32 -out:www/png.wasm -debug -o:size
