app := "/Applications/PromptBox.app"
lsregister := "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# List the recipes
default:
    @just --list

# Build, sign and register build/PromptBox.app
build:
    ./scripts/build-app.sh

# Run the core tests
test:
    swift test

# Build and install to /Applications, replacing and restarting a running copy
install: build
    #!/bin/sh
    set -eu
    # Quit through AppleScript so PromptBox saves its tabs first.
    if pgrep -x PromptBox >/dev/null; then
        osascript -e 'quit app id "no.devda.PromptBox"'
        while pgrep -x PromptBox >/dev/null; do sleep 0.2; done
    fi
    rm -rf "{{app}}"
    ditto build/PromptBox.app "{{app}}"
    # promptbox:// should open the installed copy, not the one in build/.
    "{{lsregister}}" -u build/PromptBox.app
    "{{lsregister}}" -f "{{app}}"
    open -g "{{app}}"
    echo "Installed {{app}}"
