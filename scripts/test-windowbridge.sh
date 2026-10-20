#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
package_dir="$project_dir"
mkdir -p "$package_dir/.build"
swiftc "$package_dir/Sources/WindowBridgeCore/Selection.swift" "$package_dir/Tests/WindowBridgeCoreTests/SelectionTests.swift" -o "$package_dir/.build/selection-tests"
"$package_dir/.build/selection-tests"
swiftc "$package_dir/Sources/WindowBridge/SwitcherPanel.swift" "$package_dir/Tests/WindowBridgeCoreTests/PanelTests.swift" -o "$package_dir/.build/panel-tests"
"$package_dir/.build/panel-tests"
swiftc "$package_dir/Sources/WindowBridgeCore/InputConfiguration.swift" "$package_dir/Tests/WindowBridgeCoreTests/InputSettingsTests.swift" -o "$package_dir/.build/input-tests"
"$package_dir/.build/input-tests" "$package_dir/Fixtures/karabiner-example.json"
swiftc "$package_dir/Sources/WindowBridgeCore/InputConfiguration.swift" "$package_dir/Sources/WindowBridgeCore/InputSettingsRepository.swift" "$package_dir/Tests/WindowBridgeCoreTests/RepositoryTests.swift" -o "$package_dir/.build/repository-tests"
"$package_dir/.build/repository-tests" "$package_dir/Fixtures/karabiner-example.json"
