# Contributing

## Prerequisites

- macOS 13 or later
- Xcode Command Line Tools
- Network access to nodejs.org and the npm registry for full packaging

## Local checks

Run the static and compile checks before opening a pull request:

```bash
./scripts/check.sh
```

`./build.sh` performs the full packaging flow and installs the local app bundle.
Run `swift scripts/generate-icon.swift <output.iconset>` when modifying the
code-generated app icon, then use `iconutil` to regenerate `Resources/AppIcon.icns`.

## Pull requests

- Keep each change focused.
- Do not commit `.app` bundles, `node_modules`, model credentials, or local logs.
- Describe any change to service ownership, port selection, or process shutdown behavior.
- Include the command used to verify the change.
