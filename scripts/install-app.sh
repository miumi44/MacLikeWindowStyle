#!/bin/zsh
set -eu
repo_dir="${0:A:h:h}"
app_source="$repo_dir/dist/WindowBridge.app"
app_target="$HOME/Applications/WindowBridge.app"
[[ -d "$app_source" ]] || { print 'Run ./scripts/build-windowbridge.sh first.'; exit 1; }
codesign --verify --deep --strict "$app_source"
mkdir -p "$HOME/Applications"
if [[ -e "$app_target" ]]; then
 print 'WindowBridge.app already exists in ~/Applications. Quit it and move the old app to Trash before installing.'
 exit 1
fi
ditto "$app_source" "$app_target"
print -r -- "Installed: $app_target"
print 'Open the installed app and grant its requested macOS permissions. To uninstall, quit it and move the app to Trash.'
