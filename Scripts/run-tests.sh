#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it guards,
# so a harness that stops compiling means a decision leaked out of a pure layer. See docs/testing.md.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final AND-OR list
# member, which is how CI reported success over a harness that had not compiled since phase 10.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/blitz-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall the suite.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((BLITZ_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$BLITZ_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${BLITZ_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
: > "$QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` merges each harness's compile command into .compile instead of running anything.
# xcodebuild never compiles the harnesses, so without this nothing in Tests/ resolves in an editor.
# The source lists below are the only copy, which is why this lives here rather than in its own script.
emit_db=0
DB="${TMPDIR:-/tmp}/blitz-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# run [slow] [-O] [index] <name> <source...> — queue the harness. `slow` dispatches it in the first
# wave; `index` claims editor flags for a harness that is compiled by hand rather than by the suite.
run() {
    local opt=-Onone pri=1 index_only=0
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths throughout: sourcekit-lsp resolves the command itself and does not apply
    # `directory` to relative arguments, so a relative path there silently yields no index.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Claim every file under `Tests/`: the harness and any helper compiled beside it. A shipped
        # source stays unclaimed, because it would get this short command instead of the app's full
        # one and `.compile` is last-wins — but the app never compiles anything in `Tests/`.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$QUEUE"
}

L=Blitz/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherSuggestions.swift
run file-search-test       $L/SearchRelevance.swift \
                           Blitz/Features/FileSearch/Model/*.swift
run file-search-session-test Blitz/Platform/Signposts.swift \
                             $L/SearchRelevance.swift \
                             Blitz/Features/FileSearch/Model/*.swift \
                             Blitz/Features/FileSearch/Service/*.swift
run menu-search-test       $L/SearchRelevance.swift \
                           Blitz/Features/MenuSearch/Model/*.swift \
                           Blitz/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Blitz/Features/WindowSwitcher/Model/*.swift
run index file-search-performance Blitz/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Blitz/Features/FileSearch/Model/*.swift \
                           Blitz/Features/FileSearch/Service/FileSearchService.swift
run ranking-test           $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run query-history-test     $L/LauncherQueryHistory.swift $L/LauncherQueryHistoryStore.swift
run app-name-test          Blitz/Platform/AppDisplayName.swift \
                           Blitz/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run apple-shortcut-test    Blitz/Features/AppleShortcuts/Model/*.swift
run calc-test              Blitz/Features/Calculator/Model/*.swift
run index calc-performance Blitz/Features/Calculator/Model/*.swift
# The chat tools' catalogs speak the AI layer's tool shapes, so both harnesses compile those too.
A=Blitz/Features/AI/Model
run calendar-test          Blitz/Features/Calendar/Model/*.swift \
                           $A/AITool.swift $A/JSONValue.swift $A/AIToolDate.swift \
                           $A/AIToolArguments.swift $A/AIToolJSON.swift
run reminders-test         Blitz/Features/Reminders/Model/*.swift \
                           $A/AITool.swift $A/JSONValue.swift $A/AIToolDate.swift \
                           $A/AIToolArguments.swift $A/AIToolJSON.swift
run contacts-test          Blitz/Features/Contacts/Model/*.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-test         Blitz/Features/Clipboard/Model/ClipboardStore.swift \
                           Blitz/Features/Clipboard/Model/ClipboardRichFormat.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorFormat.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift \
                           Blitz/Features/Clipboard/Model/ClipDragPayload.swift $Q
run clipboard-search-test  Blitz/Features/Clipboard/Model/*.swift $Q
run paste-sequence-test    Blitz/Features/Clipboard/Model/*.swift $Q
run clipboard-text-test    Blitz/Features/Clipboard/Model/*.swift $Q \
                           Blitz/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Blitz/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Blitz/Features/Clipboard/Service/ClipboardTextWorker.swift \
                           Blitz/Platform/ProcessExit.swift
run pasteboard-test        Blitz/Platform/PasteboardFiles.swift \
                           Blitz/Features/Clipboard/Model/ClipboardStore.swift \
                           Blitz/Features/Clipboard/Model/ClipboardRichFormat.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorFormat.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift \
                           Blitz/Features/Clipboard/Service/ClipboardManager.swift \
                           Blitz/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Blitz/Platform/PasteboardFiles.swift \
                           Blitz/Features/Clipboard/Model/ClipboardStore.swift \
                           Blitz/Features/Clipboard/Model/ClipboardRichFormat.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorFormat.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift \
                           Blitz/Features/Clipboard/Service/ClipboardManager.swift
run emoji-test             Blitz/Features/Emoji/Model/EmojiCatalog.swift \
                           Blitz/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Blitz/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Blitz/Features/Emoji/Model/EmojiCatalog.swift \
                           Blitz/Features/Emoji/Model/EmojiData.generated.swift \
                           Blitz/Features/Emoji/Service/EmojiIndex.swift \
                           Blitz/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Blitz/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Blitz/Features/Launcher/Model/SearchRelevance.swift \
                           Blitz/Platform/AppPaths.swift Blitz/Platform/Memo.swift
run index emoji-search-performance \
                           Blitz/Features/Emoji/Model/EmojiCatalog.swift \
                           Blitz/Features/Emoji/Model/EmojiData.generated.swift \
                           Blitz/Features/Emoji/Service/EmojiIndex.swift \
                           Blitz/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Blitz/Features/Launcher/Model/SearchRelevance.swift \
                           Blitz/Platform/AppPaths.swift Blitz/Platform/Memo.swift
run palette-selection-test Blitz/Features/PaletteRowIndex.swift \
                           Blitz/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Features/Settings/AppAppearance.swift
run interface-size-test    Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Features/Settings/InterfaceSize.swift \
                           Blitz/Features/Extensions/Model/ExtensionFormMetrics.swift
run palette-placement-test Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Features/Settings/InterfaceSize.swift \
                           Blitz/Palette/PalettePlacement.swift
run scroll-reveal-test     Blitz/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Blitz/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Blitz/DesignSystem/Interaction/KeyboardFocus.swift
run ai-instructions-test   Blitz/Features/AI/Model/AIInstructions.swift \
                           Blitz/Features/AI/Model/AIPreamble.swift
run hover-arming-test      Blitz/Palette/HoverArming.swift \
                           Blitz/Palette/PaletteState.swift \
                           Blitz/Palette/PaletteMode.swift \
                           Blitz/Features/Emoji/Model/EmojiCatalog.swift \
                           Blitz/Features/Clipboard/Model/ClipboardStore.swift \
                           Blitz/Features/Clipboard/Model/ClipboardRichFormat.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Blitz/Features/FileSearch/Model/FileSearchFilter.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorFormat.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run palette-escape-test    Blitz/Palette/PaletteMode.swift \
                           Blitz/Palette/PaletteEscapeAction.swift \
                           Blitz/Palette/CommandEscapeTap.swift \
                           Blitz/Features/Settings/EscapeKeyBehavior.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Blitz/Palette/PaletteState.swift \
                           Blitz/Palette/PaletteMode.swift \
                           Blitz/Palette/HoverArming.swift \
                           Blitz/Features/Emoji/Model/EmojiCatalog.swift \
                           Blitz/Features/Clipboard/Model/ClipboardStore.swift \
                           Blitz/Features/Clipboard/Model/ClipboardRichFormat.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFilter.swift \
                           Blitz/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Blitz/Features/FileSearch/Model/FileSearchFilter.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorFormat.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Blitz/Palette/PaletteMode.swift \
                           Blitz/Palette/PaletteFilterAction.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Blitz/Palette/ActionMenuSearchQuery.swift \
                            Blitz/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Blitz/Palette/PaletteShortcut.swift
run ascii-layout-test      Blitz/Platform/ASCIIKeyboardLayout.swift
run palette-tab-test       Blitz/Palette/PaletteMode.swift \
                           Blitz/Palette/PaletteTabAction.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Blitz/Features/Launcher/Model/Fallback.swift \
                           Blitz/Features/Launcher/Model/WebSearchEngine.swift \
                           Blitz/Features/Launcher/Model/CommandID.swift \
                           Blitz/Features/HotKeys/Model/HotKeyAction.swift \
                           Blitz/Features/QuickActions/Model/QuickAction.swift \
                           Blitz/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Blitz/Features/QuickActions/Model/CustomQuickAction.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/SystemActions/Model/SystemAction.swift \
                           Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/Snippets/Model/Snippet.swift
run deeplink-test          Blitz/Features/HotKeys/Model/HotKeyActionDeepLink.swift \
                           Blitz/Features/HotKeys/Model/HotKeyAction.swift \
                           Blitz/Features/Launcher/Model/CommandID.swift \
                           Blitz/Features/QuickActions/Model/QuickAction.swift \
                           Blitz/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Blitz/Features/QuickActions/Model/CustomQuickAction.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/SystemActions/Model/SystemAction.swift \
                           Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/Snippets/Model/Snippet.swift \
                           Blitz/Features/Extensions/Model/ExtensionDeepLink.swift \
                           Blitz/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run dictionary-test        Blitz/Features/Dictionary/Model/DictionaryEntry.swift \
                           Blitz/Features/Dictionary/Model/DictionaryMarkup.swift
run hotkey-test            Blitz/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Blitz/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Blitz/Features/HotKeys/Model/GlobeTapDetector.swift \
                           Blitz/Features/HotKeys/Model/HotKeyBinding.swift \
                           Blitz/Features/HotKeys/Model/HotKeySpelling.swift \
                           Blitz/Features/HotKeys/Model/HyperKey.swift \
                           Blitz/Features/HotKeys/Model/SpotlightShortcut.swift \
                           Blitz/Platform/ASCIIKeyboardLayout.swift \
                           Blitz/Features/HotKeys/Service/KeyShortcut.swift \
                           Blitz/Features/HotKeys/Model/HotKeyAction.swift \
                           Blitz/Features/QuickActions/Model/QuickAction.swift \
                           Blitz/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Blitz/Features/QuickActions/Model/CustomQuickAction.swift \
                           Blitz/Features/Launcher/Model/CommandID.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/SystemActions/Model/SystemAction.swift \
                           Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/Snippets/Model/Snippet.swift
run callout-test          Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Blitz/Platform/Appearance.swift \
                           Blitz/Platform/Images/IconCache.swift
run entry-icon-test        Blitz/Platform/Appearance.swift \
                           Blitz/Platform/Images/IconCache.swift \
                           Blitz/Platform/Images/FileIconStamp.swift
run ext-icon-test          Blitz/Platform/Appearance.swift \
                           Blitz/Platform/AppDisplayName.swift \
                           Blitz/Platform/Images/IconCache.swift \
                           Blitz/Platform/Compression/Zlib.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Blitz/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Blitz/Features/Extensions/Model/ExtensionManifest.swift \
                           Blitz/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Blitz/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Blitz/Features/Extensions/Model/RenderNode.swift \
                           Blitz/Features/Extensions/Service/ExtensionCatalog.swift \
                           Blitz/Features/Extensions/Service/ExtensionFetcher.swift \
                           Blitz/Platform/ProcessExit.swift \
                           Blitz/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Blitz/Features/Extensions/Service/ExtensionOAuthKeychain.swift \
                           Blitz/Features/Extensions/Service/ExtensionOAuthSession.swift \
                           Blitz/Features/Extensions/Service/ExtensionRuntime.swift \
                           Blitz/Features/Extensions/Service/ExtensionIconCache.swift \
                           Blitz/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Blitz/Features/Extensions/UI/ExtensionImage.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift
run system-action-test     Blitz/Features/SystemActions/Model/SystemAction.swift
run volume-test            Blitz/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/WindowManagement/Model/WindowCycle.swift \
                           Blitz/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Blitz/Features/WindowManagement/Model/WindowActionMemory.swift
run window-preset-test     Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/WindowManagement/Model/WindowShortcutPreset.swift \
                           Blitz/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Blitz/Features/HotKeys/Model/HotKeyBinding.swift \
                           Blitz/Features/HotKeys/Model/HyperKey.swift \
                           Blitz/Platform/ASCIIKeyboardLayout.swift \
                           Blitz/Features/HotKeys/Service/KeyShortcut.swift
run space-gesture-test     Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/WindowManagement/Model/SpaceGesture.swift
run window-layout-test     Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/WindowManagement/Model/WindowCycle.swift \
                           Blitz/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayout.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Blitz/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Blitz/Features/WindowManagement/Model/CustomWindowSizeStore.swift
run window-room-test       Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/WindowManagement/Model/WindowCycle.swift \
                           Blitz/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayout.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Blitz/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Blitz/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Blitz/Features/WindowManagement/Model/RoomGrid.swift \
                           Blitz/Features/WindowManagement/Model/RoomWindow.swift \
                           Blitz/Features/WindowManagement/Model/Room.swift \
                           Blitz/Features/WindowManagement/Model/RoomWindowMatcher.swift \
                           Blitz/Features/WindowManagement/Model/RoomParking.swift \
                           Blitz/Features/WindowManagement/Model/RoomPlan.swift \
                           Blitz/Features/WindowManagement/Model/RoomArrangement.swift \
                           Blitz/Features/WindowManagement/Model/RoomStore.swift \
                           Blitz/Features/WindowManagement/Model/RoomMinimumSizeStore.swift \
                           Blitz/Features/WindowManagement/Model/RoomParkingLedger.swift
run window-file-test       Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           Blitz/Features/WindowManagement/Model/WindowCycle.swift \
                           Blitz/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayout.swift \
                           Blitz/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Blitz/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Blitz/Features/WindowManagement/Model/Room.swift \
                           Blitz/Features/WindowManagement/Model/RoomWindow.swift \
                           Blitz/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Blitz/Features/WindowManagement/Model/RoomGrid.swift \
                           Blitz/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Blitz/Features/WindowManagement/Model/WindowManagementFileFormat.swift \
                           Blitz/Features/Settings/Model/SettingsFileJSON.swift \
                           Blitz/Features/Settings/Model/SettingsFileIdentity.swift
run custom-command-test    Blitz/Platform/PseudoTerminal.swift \
                           Blitz/Platform/ProcessExit.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift \
                           Blitz/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Blitz/Features/CustomCommands/Service/ShellCommandRunner.swift
run uninstall-test         Blitz/Features/Uninstall/Model/UninstallTarget.swift \
                           Blitz/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Blitz/Features/Uninstall/Model/UninstallRules.swift \
                           Blitz/Features/Uninstall/Model/UninstallProtection.swift \
                           Blitz/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Blitz/Platform/BrowserTab.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkFavicon.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Blitz/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run slow snippets-test     Blitz/Platform/NotificationToken.swift \
                           Blitz/Platform/HealthTicker.swift \
                           Blitz/Platform/BrowserTab.swift \
                           Blitz/Platform/AccessibilityText.swift \
                           Blitz/Features/Snippets/Model/*.swift \
                           Blitz/Features/Snippets/Service/*.swift \
                           Blitz/Features/TextInjection/Service/*.swift
run notes-test             Blitz/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Blitz/Features/Notes/Model/*.swift \
                           Blitz/Features/Notes/Service/*.swift
run notes-editor-test      Blitz/Platform/Signposts.swift \
                           Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Platform/NotificationToken.swift \
                           Blitz/Features/TextInjection/Service/InjectableTextView.swift \
                           Blitz/Features/Notes/Model/NoteDocument.swift \
                           Blitz/Features/Notes/Model/NoteMarkdown.swift \
                           Blitz/Features/Notes/Model/NoteMarkdownParser.swift \
                           Blitz/Features/Notes/Model/NoteInlineScanner.swift \
                           Blitz/Features/Notes/Model/NoteEditPlan.swift \
                           Blitz/Features/Notes/Model/NoteEditAction.swift \
                           Blitz/Features/Notes/Model/NoteFormatting.swift \
                           Blitz/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Blitz/Features/Notes/Model/NoteRevealPolicy.swift \
                           Blitz/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Blitz/Features/Notes/UI/NoteBlockDecoration.swift \
                           Blitz/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Blitz/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Blitz/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Blitz/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Blitz/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Blitz/Features/Notes/UI/NoteTextViewEditing.swift \
                           Blitz/Features/Notes/UI/NoteTextView.swift \
                           Blitz/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Blitz/Platform/Signposts.swift \
                           Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Platform/NotificationToken.swift \
                           Blitz/Features/TextInjection/Service/InjectableTextView.swift \
                           Blitz/Features/Notes/Model/NoteDocument.swift \
                           Blitz/Features/Notes/Model/NoteMarkdown.swift \
                           Blitz/Features/Notes/Model/NoteMarkdownParser.swift \
                           Blitz/Features/Notes/Model/NoteInlineScanner.swift \
                           Blitz/Features/Notes/Model/NoteEditPlan.swift \
                           Blitz/Features/Notes/Model/NoteEditAction.swift \
                           Blitz/Features/Notes/Model/NoteFormatting.swift \
                           Blitz/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Blitz/Features/Notes/Model/NoteRevealPolicy.swift \
                           Blitz/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Blitz/Features/Notes/UI/NoteBlockDecoration.swift \
                           Blitz/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Blitz/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Blitz/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Blitz/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Blitz/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Blitz/Features/Notes/UI/NoteTextViewEditing.swift \
                           Blitz/Features/Notes/UI/NoteTextView.swift \
                           Blitz/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Blitz/Features/Backup/Model/RaycastImportError.swift \
                           Blitz/Features/Backup/Service/RaycastDecoder.swift \
                           Blitz/Features/Backup/Service/Scrypt.swift \
                           Blitz/Platform/Compression/Zlib.swift
run settings-backup-test   Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/Backup/Model/SettingsBackupCoverage.swift
run settings-file-test     Blitz/Features/Settings/Model/*.swift \
                           Blitz/Features/Settings/Service/SettingsFileMonitor.swift \
                           Blitz/Features/Settings/Service/SettingsFileRepository.swift \
                           Blitz/Platform/AppPaths.swift
run backup-archive-test    Blitz/Platform/AppPaths.swift \
                           Blitz/Features/Backup/Model/BackupArchive.swift \
                           Blitz/Features/Backup/Model/BackupBundle.swift \
                           Blitz/Features/Backup/Model/BackupCategory.swift \
                           Blitz/Features/Backup/Model/BackupClipboardItem.swift \
                           Blitz/Features/Backup/Model/BackupManifest.swift \
                           Blitz/Features/Backup/Service/BackupStaging.swift
E=Blitz/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Blitz/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Blitz/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-version-test       $E/Model/ExtensionListing.swift \
                           $E/Model/ExtensionUpdatePolicy.swift \
                           $E/Service/ExtensionVersionStore.swift
run ext-store-test         $E/Model/ExtensionGitHubSource.swift \
                           $E/Model/ExtensionListing.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift \
                           $E/Model/ExtensionStoreReadme.swift \
                           $E/Model/ExtensionPagination.swift \
                           $E/Model/RenderNode.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Tests/ext-menu-bar-test.swift \
                           Tests/ext-fetch-test.swift \
                           $E/Model/ExtensionLaunchError.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionStorage.swift \
                           $E/Service/ExtensionMenuBarManager.swift \
                           $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift \
                           $E/UI/ExtensionMenuBarController.swift \
                           $E/UI/ExtensionMenuBarImage.swift \
                           Blitz/Platform/Appearance.swift \
                           Blitz/Platform/AppDisplayName.swift \
                           Blitz/Platform/Images/IconCache.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           Blitz/Platform/ProcessExit.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionOAuthKeychain.swift \
                           $E/Service/ExtensionOAuthSession.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $E/Model/ExtensionPagination.swift \
                           $L/SearchRelevance.swift \
                           Blitz/Platform/Compression/Zlib.swift \
                           Blitz/Features/Clipboard/Model/ColorValue.swift \
                           Blitz/Features/Clipboard/Model/ColorSpaces.swift
run settings-history-test  Blitz/Features/Settings/SettingsTab.swift \
                           Blitz/Features/Settings/SettingsHistory.swift \
                           Blitz/Features/Settings/SettingsAnchor.swift \
                           Blitz/Features/Settings/SettingsNavigationState.swift \
                           Blitz/Features/Settings/SettingsSearchCatalog.swift \
                           Blitz/Features/WindowManagement/Model/WindowCommand.swift \
                           $L/SearchRelevance.swift
run updates-test           Blitz/Features/Updates/Model/*.swift \
                           Blitz/Features/Updates/Service/BundleSignature.swift
run support-test           Blitz/Features/Support/Model/*.swift
run onboarding-test        Blitz/Features/Onboarding/Model/*.swift \
                           Blitz/Palette/PaletteMode.swift \
                           Blitz/Palette/PaletteTabAction.swift \
                           Blitz/Features/Quicklinks/Model/Quicklink.swift \
                           Blitz/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Blitz/Features/CustomCommands/Model/CustomCommand.swift
run ai-provider-test       Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/AI/Model/*.swift \
                           Blitz/Features/AI/Settings/AISettingsStore.swift
run ai-chat-test           Blitz/Features/AI/Model/AIRequest.swift \
                           Blitz/Features/AI/Model/AIConnection.swift \
                           Blitz/Features/AI/Model/AppleIntelligence.swift \
                           Blitz/Features/AI/Model/AIAttachmentPolicy.swift \
                           Blitz/Features/AI/Model/AIRetention.swift \
                           Blitz/Features/AI/Model/AITool.swift \
                           Blitz/Features/AI/Model/JSONValue.swift \
                           Blitz/Features/AI/Model/ChatMessage.swift \
                           Blitz/Features/AI/Model/ChatSession.swift \
                           Blitz/Features/AI/Model/ChatChoices.swift \
                           Blitz/Features/AI/Model/ChatReferences.swift \
                           Blitz/Features/AI/Model/ChatTitle.swift \
                           Blitz/Features/AI/Model/ChatFind.swift \
                           Blitz/Features/AI/Model/ChatCitations.swift \
                           Blitz/Features/AI/Model/ChatToolScope.swift \
                           Blitz/Features/AI/Model/MarkdownBlock.swift \
                           Blitz/Features/AI/Model/MarkdownMath.swift \
                           Blitz/Features/AI/Model/MathFormula.swift \
                           Blitz/Features/AI/Model/MathNode.swift \
                           Blitz/Features/AI/Model/MathSymbolCatalog.swift \
                           Blitz/Features/AI/Service/AIProvider.swift \
                           Blitz/Features/AI/Service/ChatHistoryStore.swift \
                           Blitz/Features/AI/Service/AIToolLoopProvider.swift \
                           Blitz/Features/AI/UI/AIChatState.swift \
                           Blitz/Features/AI/UI/AIChatSurfacesState.swift \
                           Blitz/Features/AI/UI/ChatFindState.swift
run chat-markdown-test     Blitz/Platform/Appearance.swift \
                           Blitz/DesignSystem/Theme.swift \
                           Blitz/DesignSystem/InterfaceMetrics.swift \
                           Blitz/Features/Settings/InterfaceSize.swift \
                           Blitz/Features/AI/Model/AIRequest.swift \
                           Blitz/Features/AI/Model/AITool.swift \
                           Blitz/Features/AI/Model/JSONValue.swift \
                           Blitz/Features/AI/Model/ChatMessage.swift \
                           Blitz/Features/AI/Model/ChatChoices.swift \
                           Blitz/Features/AI/Model/ChatReferences.swift \
                           Blitz/Features/AI/Model/ChatCitations.swift \
                           Blitz/Features/AI/Model/ChatFind.swift \
                           Blitz/Features/AI/Model/MarkdownBlock.swift \
                           Blitz/Features/AI/Model/MarkdownMath.swift \
                           Blitz/Features/AI/Model/MathFormula.swift \
                           Blitz/Features/AI/Model/MathNode.swift \
                           Blitz/Features/AI/Model/MathSymbolCatalog.swift \
                           Blitz/Features/AI/UI/ChatTextHighlight.swift \
                           Blitz/Features/AI/UI/ChatMarkdownRenderer.swift \
                           Blitz/Features/AI/UI/MathAttachmentCell.swift \
                           Blitz/Features/AI/UI/MathBox.swift \
                           Blitz/Features/AI/UI/MathFont.swift \
                           Blitz/Features/AI/UI/MathLayoutEngine.swift
run mcp-test               Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/AI/Model/AIConnection.swift \
                           Blitz/Features/AI/Model/AppleIntelligence.swift \
                           Blitz/Features/AI/Model/AITool.swift \
                           Blitz/Features/AI/Model/AIToolServer.swift \
                           Blitz/Features/AI/Model/JSONValue.swift \
                           Blitz/Features/MCP/Model/*.swift \
                           Blitz/Features/MCP/Settings/MCPSettingsStore.swift
run -O text-diff-test      Blitz/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Blitz/Features/QuickActions/Model/TextDiffEngine.swift
run quick-action-test      Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/AI/Model/AIConnection.swift \
                           Blitz/Features/AI/Model/AppleIntelligence.swift \
                           Blitz/Features/AI/Model/ChatGPTSubscription.swift \
                           Blitz/Features/AI/Model/InstalledAI.swift \
                           Blitz/Features/QuickActions/Model/*.swift \
                           Blitz/Features/QuickActions/Settings/QuickActionSettingsStore.swift
run apple-intelligence-test Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/AI/Model/*.swift \
                           Blitz/Features/AI/Service/AIProvider.swift \
                           Blitz/Features/AI/Service/AppleIntelligenceProvider.swift
run mcp-oauth-test         Blitz/Platform/ExecutableLocator.swift \
                           Blitz/Platform/ProcessExit.swift \
                           Blitz/Platform/KeychainSecretStore.swift \
                           Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/AI/Model/AIConnection.swift \
                           Blitz/Features/AI/Model/AppleIntelligence.swift \
                           Blitz/Features/AI/Model/AITool.swift \
                           Blitz/Features/AI/Model/AIToolServer.swift \
                           Blitz/Features/AI/Model/AIStreamDecoder.swift \
                           Blitz/Features/AI/Model/AIThinkTagDecoder.swift \
                           Blitz/Features/AI/Model/AIRequest.swift \
                           Blitz/Features/AI/Model/JSONValue.swift \
                           Blitz/Features/MCP/Model/*.swift \
                           Blitz/Features/MCP/Service/*.swift
run slow mcp-stdio-test    Blitz/Platform/ExecutableLocator.swift \
                           Blitz/Platform/ProcessExit.swift \
                           Blitz/Platform/KeychainSecretStore.swift \
                           Blitz/Features/Settings/AppSettingsKey.swift \
                           Blitz/Features/AI/Model/AIConnection.swift \
                           Blitz/Features/AI/Model/AppleIntelligence.swift \
                           Blitz/Features/AI/Model/AITool.swift \
                           Blitz/Features/AI/Model/AIToolServer.swift \
                           Blitz/Features/AI/Model/AIStreamDecoder.swift \
                           Blitz/Features/AI/Model/AIThinkTagDecoder.swift \
                           Blitz/Features/AI/Model/AIRequest.swift \
                           Blitz/Features/AI/Model/JSONValue.swift \
                           Blitz/Features/MCP/Model/*.swift \
                           Blitz/Features/MCP/Service/*.swift
run slow codex-turn-test   Blitz/Platform/AppPaths.swift \
                           Blitz/Features/AI/Model/*.swift \
                           Blitz/Features/AI/Service/AIProvider.swift \
                           Blitz/Features/AI/Service/ChatGPTSubscriptionManager.swift \
                           Blitz/Features/AI/Service/CodexAppServerClient.swift \
                           Blitz/Features/AI/Service/InstalledAIProbe.swift \
                           Blitz/Platform/ExecutableLocator.swift \
                           Blitz/Platform/ProcessExit.swift \
                           Blitz/Features/AI/Service/CodexTurnRunner.swift
run installed-ai-test     Blitz/Features/AI/Model/*.swift \
                          Blitz/Features/AI/Service/AIProvider.swift \
                          Blitz/Platform/AppPaths.swift \
                          Blitz/Platform/ExecutableLocator.swift \
                          Blitz/Platform/ProcessExit.swift \
                          Blitz/Features/AI/Service/InstalledCLIProvider.swift \
                          Blitz/Features/AI/Service/InstalledAIProbe.swift \
                          Blitz/Features/AI/Service/InstalledAIManager.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${BLITZ_TEST_JOBS:-$(sysctl -n hw.ncpu)}"
export BLITZ_TEST_TIMEOUT="${BLITZ_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! { sort -s -k1,1n "$QUEUE" | cut -d' ' -f2- | xargs -P "$JOBS" -L1 "$SELF" --exec; echo "dispatch $?"; } | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < "$QUEUE"

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
